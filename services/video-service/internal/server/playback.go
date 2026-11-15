package server

import (
	"context"
	"errors"
	"log/slog"
	"maps"
	"slices"
	"strings"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	"google.golang.org/grpc/codes"

	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/hls"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/logx"
	"github.com/anhnvcoder/svp-backend/internal/mediasign"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
)

// renditionTiers maps each rendition media-worker can write (the ladder of its transcode package,
// and source) to the lowest tier that plays it. TIER_FHD plays every rendition of the ladder.
var renditionTiers = map[string]videov1.Tier{
	"source": videov1.Tier_TIER_SD,
	"360p":   videov1.Tier_TIER_SD,
	"720p":   videov1.Tier_TIER_HD,
	"1080p":  videov1.Tier_TIER_FHD,
}

// ladder lists the renditions a master playlist may name.
var ladder = slices.Sorted(maps.Keys(renditionTiers))

const (
	// masterName is the file name of the master playlist in the version directory.
	masterName = "master.m3u8"
	// maxPlaylistBytes bounds one playlist read from storage: some 7 hours of 4-second segments.
	maxPlaylistBytes = 256 << 10
	// playlistCacheEntries and playlistCacheBytes bound the playlists kept in memory.
	playlistCacheEntries = 512
	playlistCacheBytes   = 16 << 20
)

// Values of the kind and result attributes of svp.video.playback.playlists.
const (
	playlistKindMaster = "master"
	playlistKindMedia  = "media"

	playlistResultOK                   = "ok"
	playlistResultNotEntitled          = "not_entitled"
	playlistResultRenditionNotEntitled = "rendition_not_entitled"
	playlistResultNotFound             = "not_found"
)

// GetPlaybackPlaylist returns a playlist of a READY premium video to its author or to a caller
// holding an entitlement. With no rendition it is the master playlist cut down to the renditions
// of the caller's tier; with one, that rendition's media playlist with every segment signed by the
// server's signer until mediasign.Expiry of the video's length. The playlists come from storage
// and are kept in memory, since they never change; the signatures are made for each call. A
// signed playlist grants read access to the segments: it is never logged.
func (s *Server) GetPlaybackPlaylist(ctx context.Context, req *videov1.GetPlaybackPlaylistRequest) (*videov1.GetPlaybackPlaylistResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	videoID, err := ids.Parse(req.GetVideoId())
	if err != nil {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidVideoID, "video_id must be a canonical lowercase UUID")
	}
	kind := playlistKindMaster
	if req.GetRendition() != "" {
		kind = playlistKindMedia
	}
	content, err := s.playbackPlaylist(ctx, caller, videoID, req.GetRendition())
	if result, counted := playlistResult(err); counted {
		s.playlistsServed.Add(ctx, 1, metric.WithAttributes(
			attribute.String("kind", kind), attribute.String("result", result)))
	}
	if err != nil {
		return nil, err
	}
	return &videov1.GetPlaybackPlaylistResponse{Content: string(content)}, nil
}

// playlistResult returns the result attribute of the outcome err of a playlist request, and
// false for an outcome that is not counted: a malformed request, a regular video, a failure.
func playlistResult(err error) (string, bool) {
	if err == nil {
		return playlistResultOK, true
	}
	switch grpcerr.Reason(err) {
	case ReasonNotEntitled:
		return playlistResultNotEntitled, true
	case ReasonRenditionNotEntitled:
		return playlistResultRenditionNotEntitled, true
	case ReasonVideoNotFound, ReasonRenditionNotFound:
		return playlistResultNotFound, true
	}
	return "", false
}

// playbackPlaylist checks the video and the caller's tier, then writes the playlist asked for.
func (s *Server) playbackPlaylist(ctx context.Context, caller, videoID uuid.UUID, rendition string) ([]byte, error) {
	v, err := s.queries.GetVideo(ctx, videoID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, videoNotFound()
	}
	if err != nil {
		return nil, s.internal(ctx, "select video", err)
	}
	// Unlike GetVideo, the author gets no playlist before READY: there is none to play yet.
	if v.Status != statusReady {
		return nil, videoNotFound()
	}
	if !v.Premium {
		return nil, grpcerr.New(codes.FailedPrecondition, ReasonVideoNotPremium, "video is not premium")
	}
	ctx = logx.With(ctx, slog.String("video_id", v.ID.String()))
	tier, err := s.entitlementTier(ctx, v, caller)
	if err != nil {
		return nil, s.internal(ctx, "select entitlement", err)
	}
	if tier == videov1.Tier_TIER_UNSPECIFIED {
		return nil, notEntitled()
	}
	allowed := func(r string) bool {
		t, ok := renditionTiers[r]
		return ok && t <= tier
	}

	id := v.ID.String()
	version, err := premiumVersion(id, v.PlaylistKey)
	if err != nil {
		return nil, s.internal(ctx, "premium playlist key", err)
	}
	dir := objstore.PremiumPrefix + id + "/" + version + "/"
	data, err := s.readPlaylist(ctx, dir+masterName)
	if err != nil {
		return nil, err
	}
	master, err := hls.ParseMaster(data, ladder)
	if err != nil {
		return nil, s.internal(ctx, "parse master playlist", err)
	}
	if rendition == "" {
		out, err := master.Filter(allowed)
		if errors.Is(err, hls.ErrNoVariant) {
			return nil, notEntitled()
		}
		if err != nil {
			return nil, s.internal(ctx, "filter master playlist", err)
		}
		return out, nil
	}

	variant, ok := master.Variant(rendition)
	if !ok {
		return nil, grpcerr.New(codes.NotFound, ReasonRenditionNotFound, "video has no such rendition")
	}
	if !allowed(rendition) {
		return nil, grpcerr.New(codes.PermissionDenied, ReasonRenditionNotEntitled, "rendition is above the caller's tier")
	}
	data, err = s.readPlaylist(ctx, dir+variant.URI)
	if err != nil {
		return nil, err
	}
	// The column allows NULL although a READY video always has a length; 0 still gives the margin.
	var length time.Duration
	if v.DurationMs != nil {
		length = time.Duration(*v.DurationMs) * time.Millisecond
	}
	sign, err := s.signer.Rendition(ctx, mediasign.Rendition{
		VideoID: id, Version: version, Attempt: variant.Attempt, Name: rendition,
	}, length)
	if err != nil {
		return nil, s.internal(ctx, "sign rendition", err)
	}
	out, err := hls.SignMedia(data, rendition, sign)
	if err != nil {
		return nil, s.internal(ctx, "sign media playlist", err)
	}
	return out, nil
}

func notEntitled() error {
	return grpcerr.New(codes.PermissionDenied, ReasonNotEntitled, "the caller holds no entitlement to the video")
}

// errPlaylistKey is returned by premiumVersion for a playlist key outside the premium layout.
var errPlaylistKey = errors.New("playlist_key is not premium/<video_id>/<version>/master.m3u8")

// premiumVersion returns the version in the master playlist key of the premium video id,
// premium/<id>/<version>/master.m3u8.
func premiumVersion(id string, key *string) (string, error) {
	if key == nil || !objstore.IsKeyUnder(objstore.PremiumPrefix, *key, id) {
		return "", errPlaylistKey
	}
	version, file, _ := strings.Cut(strings.TrimPrefix(*key, objstore.PremiumPrefix+id+"/"), "/")
	if file != masterName {
		return "", errPlaylistKey
	}
	if _, err := ids.Parse(version); err != nil {
		return "", errPlaylistKey
	}
	return version, nil
}

// readPlaylist returns the playlist at key from the cache, or from storage, caching it. A storage
// failure that may pass is UNAVAILABLE and is not cached; a missing, forbidden or oversized
// object of a READY video is INTERNAL, since retrying cannot fix it.
func (s *Server) readPlaylist(ctx context.Context, key string) ([]byte, error) {
	if data, ok := s.playlists.get(key); ok {
		return data, nil
	}
	data, err := s.storage.Read(ctx, key, maxPlaylistBytes)
	switch {
	case errors.Is(err, objstore.ErrNotFound), errors.Is(err, objstore.ErrAccessDenied),
		errors.Is(err, objstore.ErrTooLarge), errors.Is(err, objstore.ErrInvalidKey):
		return nil, s.internal(ctx, "read playlist", err)
	case err != nil:
		s.logger.ErrorContext(ctx, "read playlist", slog.Any("error", err))
		return nil, grpcerr.New(codes.Unavailable, ReasonDependencyUnavailable, "storage unavailable")
	}
	s.playlists.add(key, data)
	return data, nil
}
