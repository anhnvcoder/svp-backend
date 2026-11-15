package api

import (
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/services/gateway/internal/httpx"
)

// hlsContentType is the media type of an HLS playlist (RFC 8216 section 4).
const hlsContentType = "application/vnd.apple.mpegurl"

// tierNames are the REST names of the tiers; TIER_UNSPECIFIED has none, so a field holding it
// is left out.
var tierNames = map[videov1.Tier]string{
	videov1.Tier_TIER_SD:  "sd",
	videov1.Tier_TIER_HD:  "hd",
	videov1.Tier_TIER_FHD: "fhd",
}

// tierByName is tierNames the other way round.
var tierByName = map[string]videov1.Tier{
	"sd":  videov1.Tier_TIER_SD,
	"hd":  videov1.Tier_TIER_HD,
	"fhd": videov1.Tier_TIER_FHD,
}

type entitlementRequest struct {
	Tier string `json:"tier"`
}

// entitlementResponse is schema Entitlement.
type entitlementResponse struct {
	VideoID   string    `json:"video_id"`
	Tier      string    `json:"tier"`
	GrantedAt time.Time `json:"granted_at"`
}

// grantEntitlement records the caller's simulated purchase of a premium video. A tier that is
// not one of tierByName, a missing one included, is refused here with the reason video-service
// gives an unspecified tier, since it has no value to send. video_id goes on as it is: the
// service validates it.
func (s *server) grantEntitlement(w http.ResponseWriter, r *http.Request) {
	var req entitlementRequest
	if !httpx.DecodeJSON(w, r, &req) {
		return
	}
	tier, ok := tierByName[req.Tier]
	if !ok {
		httpx.WriteProblem(w, r, http.StatusBadRequest, "INVALID_TIER", "tier must be sd, hd or fhd")
		return
	}
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.videos.GrantEntitlement(ctx, &videov1.GrantEntitlementRequest{VideoId: r.PathValue("video_id"), Tier: tier})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	e := resp.GetEntitlement()
	writeJSON(w, http.StatusOK, entitlementResponse{
		VideoID:   e.GetVideoId(),
		Tier:      tierNames[e.GetTier()],
		GrantedAt: e.GetGrantedAt().AsTime(),
	})
}

// renditionName is the form of a rendition in a playback path; video-service knows which exist.
var renditionName = regexp.MustCompile(`^[a-z0-9]{1,16}$`)

// playbackRendition reads the {file} of a playback path: "master.m3u8" asks for the master
// playlist (rendition ""), "<rendition>.m3u8" for that rendition's media playlist. ok is false
// for any other file, which never reaches video-service.
func playbackRendition(file string) (rendition string, ok bool) {
	if file == "master.m3u8" {
		return "", true
	}
	name, found := strings.CutSuffix(file, ".m3u8")
	if !found || name == "master" || !renditionName.MatchString(name) {
		return "", false
	}
	return name, true
}

// playback serves a playlist of a premium video, rewritten for the caller by video-service: the
// master cut down to the caller's tier, or a media playlist whose segment URLs are signed. The
// body is written only once the call has returned, so an error is always a whole problem
// response. A signed playlist is a credential of the caller: no cache may keep it.
func (s *server) playback(w http.ResponseWriter, r *http.Request) {
	rendition, ok := playbackRendition(r.PathValue("file"))
	if !ok {
		httpx.WriteProblem(w, r, http.StatusNotFound, "RENDITION_NOT_FOUND", "no such playlist")
		return
	}
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.videos.GetPlaybackPlaylist(ctx, &videov1.GetPlaybackPlaylistRequest{
		VideoId:   r.PathValue("video_id"),
		Rendition: rendition,
	})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", hlsContentType)
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, resp.GetContent())
}
