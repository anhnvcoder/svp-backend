package server

import (
	"context"
	"errors"
	"log/slog"
	"uuid"

	"github.com/jackc/pgx/v5"
	"google.golang.org/grpc/codes"
	"google.golang.org/protobuf/types/known/timestamppb"

	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/logx"
	"github.com/anhnvcoder/svp-backend/services/video-service/internal/store"
)

// tierNames maps each tier an entitlement can hold to its value in video_entitlements.tier.
var tierNames = map[videov1.Tier]string{
	videov1.Tier_TIER_SD:  "sd",
	videov1.Tier_TIER_HD:  "hd",
	videov1.Tier_TIER_FHD: "fhd",
}

// tierFromName is the inverse of tierNames; an unknown name, which the column's CHECK rules out,
// is TIER_UNSPECIFIED.
func tierFromName(name string) videov1.Tier {
	for tier, n := range tierNames {
		if n == name {
			return tier
		}
	}
	return videov1.Tier_TIER_UNSPECIFIED
}

// GrantEntitlement records a simulated purchase: the caller holds tier on the premium video
// video_id. The entitlement always belongs to the caller of the token, never to a user named in
// the request. A repeated call overwrites the tier, so it is idempotent and can also change it.
// A video that is missing or not READY gets the NOT_FOUND of GetVideo.
func (s *Server) GrantEntitlement(ctx context.Context, req *videov1.GrantEntitlementRequest) (*videov1.GrantEntitlementResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	videoID, err := ids.Parse(req.GetVideoId())
	if err != nil {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidVideoID, "video_id must be a canonical lowercase UUID")
	}
	tier, ok := tierNames[req.GetTier()]
	if !ok {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidTier, "tier must be TIER_SD, TIER_HD or TIER_FHD")
	}

	v, err := s.queries.GetVideo(ctx, videoID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, videoNotFound()
	}
	if err != nil {
		return nil, s.internal(ctx, "select video", err)
	}
	if v.Status != statusReady {
		return nil, videoNotFound()
	}
	// Both are fixed once the video is READY, so checking them before the write needs no lock.
	if !v.Premium {
		return nil, grpcerr.New(codes.FailedPrecondition, ReasonVideoNotPremium, "video is not premium")
	}
	if v.AuthorID == caller {
		return nil, grpcerr.New(codes.FailedPrecondition, ReasonAlreadyEntitled, "the author already holds every tier")
	}

	ctx = logx.With(ctx, slog.String("video_id", v.ID.String()))
	e, err := s.queries.UpsertEntitlement(ctx, store.UpsertEntitlementParams{UserID: caller, VideoID: v.ID, Tier: tier})
	if err != nil {
		return nil, s.internal(ctx, "upsert entitlement", err)
	}
	s.logger.InfoContext(ctx, "entitlement granted", slog.String("tier", e.Tier))
	return &videov1.GrantEntitlementResponse{Entitlement: &videov1.Entitlement{
		VideoId:   e.VideoID.String(),
		Tier:      tierFromName(e.Tier),
		GrantedAt: timestamppb.New(e.GrantedAt),
	}}, nil
}

// entitlementTier returns the tier caller holds on v: TIER_FHD for the author of a premium video,
// the tier of caller's own entitlement otherwise, and TIER_UNSPECIFIED without one or for a
// regular video.
func (s *Server) entitlementTier(ctx context.Context, v store.Video, caller uuid.UUID) (videov1.Tier, error) {
	if !v.Premium {
		return videov1.Tier_TIER_UNSPECIFIED, nil
	}
	if v.AuthorID == caller {
		return videov1.Tier_TIER_FHD, nil
	}
	name, err := s.queries.GetEntitlementTier(ctx, store.GetEntitlementTierParams{UserID: caller, VideoID: v.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return videov1.Tier_TIER_UNSPECIFIED, nil
	}
	if err != nil {
		return videov1.Tier_TIER_UNSPECIFIED, err
	}
	return tierFromName(name), nil
}
