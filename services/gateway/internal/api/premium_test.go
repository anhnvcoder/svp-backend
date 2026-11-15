package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	feedv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/feed/v1"
	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/services/gateway/internal/httpx"
)

const (
	// premiumID is the READY premium video of premiumVideos and premiumFeed, by author userA.
	premiumID = "01928c6e-7b3a-7cde-8f01-555555555555"
	// leakedID is a premium feed item whose playlist_key wrongly sits under premium/.
	leakedID = "01928c6e-7b3a-7cde-8f01-666666666666"
	// fakeMaster and fakeSigned are what fakeVideos' GetPlaybackPlaylist answers.
	fakeMaster = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n360p.m3u8\n"
	fakeSigned = "#EXTM3U\n#EXTINF:4.0,\nhttps://cdn.example/premium/x/index_360p_00000.ts?Signature=s\n#EXT-X-ENDLIST\n"
)

var grantedAt = time.Date(2026, 11, 15, 1, 2, 3, 0, time.UTC)

// GrantEntitlement answers the entitlement asked for, as video-service does for a READY premium
// video of another author.
func (fakeVideos) GrantEntitlement(_ context.Context, req *videov1.GrantEntitlementRequest) (*videov1.GrantEntitlementResponse, error) {
	return &videov1.GrantEntitlementResponse{Entitlement: &videov1.Entitlement{
		VideoId:   req.GetVideoId(),
		Tier:      req.GetTier(),
		GrantedAt: timestamppb.New(grantedAt),
	}}, nil
}

// GetPlaybackPlaylist answers fakeMaster for the master and fakeSigned for any rendition.
func (fakeVideos) GetPlaybackPlaylist(_ context.Context, req *videov1.GetPlaybackPlaylistRequest) (*videov1.GetPlaybackPlaylistResponse, error) {
	if req.GetRendition() == "" {
		return &videov1.GetPlaybackPlaylistResponse{Content: fakeMaster}, nil
	}
	return &videov1.GetPlaybackPlaylistResponse{Content: fakeSigned}, nil
}

// premiumVideos is fakeVideos with premiumID: a READY premium video by userA, of which userB
// holds TIER_SD. Its lists hold premiumID and the regular videoID.
type premiumVideos struct {
	fakeVideos
}

func premiumVideo() *videov1.Video {
	return &videov1.Video{
		VideoId:            premiumID,
		AuthorId:           userA,
		Title:              "premium clip",
		Status:             videov1.VideoStatus_VIDEO_STATUS_READY,
		Duration:           durationpb.New(30 * time.Second),
		PlaylistKey:        "premium/" + premiumID + "/v1/master.m3u8",
		ThumbnailKey:       "preview/" + premiumID + "/v1/a1/thumbnail.jpg",
		CreatedAt:          timestamppb.New(createdAt),
		PublishedAt:        timestamppb.New(publishedAt),
		Premium:            true,
		PreviewPlaylistKey: "preview/" + premiumID + "/v1/master.m3u8",
	}
}

func (p premiumVideos) GetVideo(ctx context.Context, req *videov1.GetVideoRequest) (*videov1.GetVideoResponse, error) {
	if req.GetVideoId() != premiumID {
		return p.fakeVideos.GetVideo(ctx, req)
	}
	md, _ := metadata.FromIncomingContext(ctx)
	tier := videov1.Tier_TIER_UNSPECIFIED
	switch c := callers(md); {
	case slices.Equal(c, []string{userA}):
		tier = videov1.Tier_TIER_FHD
	case slices.Equal(c, []string{userB}):
		tier = videov1.Tier_TIER_SD
	}
	return &videov1.GetVideoResponse{Video: premiumVideo(), EntitlementTier: tier}, nil
}

func (p premiumVideos) GetPublicVideo(ctx context.Context, req *videov1.GetPublicVideoRequest) (*videov1.GetPublicVideoResponse, error) {
	if req.GetVideoId() != premiumID {
		return p.fakeVideos.GetPublicVideo(ctx, req)
	}
	return &videov1.GetPublicVideoResponse{Video: premiumVideo()}, nil
}

// CompleteUpload answers premiumID as READY, a repeated call; any other id as fakeVideos does.
func (p premiumVideos) CompleteUpload(ctx context.Context, req *videov1.CompleteUploadRequest) (*videov1.CompleteUploadResponse, error) {
	if req.GetVideoId() != premiumID {
		return p.fakeVideos.CompleteUpload(ctx, req)
	}
	return &videov1.CompleteUploadResponse{Video: premiumVideo()}, nil
}

func (p premiumVideos) ListAuthorVideos(ctx context.Context, _ *videov1.ListAuthorVideosRequest) (*videov1.ListAuthorVideosResponse, error) {
	regular, _ := p.fakeVideos.GetVideo(ctx, &videov1.GetVideoRequest{VideoId: videoID})
	return &videov1.ListAuthorVideosResponse{Videos: []*videov1.Video{premiumVideo(), regular.GetVideo()}}, nil
}

// premiumFeed answers both feeds with premiumID as feed-service stores it (its preview), the
// regular videoID, and leakedID, whose key under premium/ the gateway must not turn into a URL.
type premiumFeed struct {
	feedv1.UnimplementedFeedServiceServer
}

func premiumFeedItems() []*feedv1.FeedItem {
	item := func(id, playlistKey string, premium bool) *feedv1.FeedItem {
		return &feedv1.FeedItem{
			VideoId:      id,
			AuthorId:     userA,
			Title:        "clip " + id,
			Duration:     durationpb.New(30 * time.Second),
			PlaylistKey:  playlistKey,
			ThumbnailKey: strings.Replace(playlistKey, "master.m3u8", "a1/thumbnail.jpg", 1),
			PublishedAt:  timestamppb.New(publishedAt),
			Premium:      premium,
		}
	}
	return []*feedv1.FeedItem{
		item(premiumID, "preview/"+premiumID+"/v1/master.m3u8", true),
		item(videoID, "media/"+videoID+"/v1/master.m3u8", false),
		item(leakedID, "premium/"+leakedID+"/v1/master.m3u8", true),
	}
}

func (premiumFeed) GetFollowingFeed(context.Context, *feedv1.GetFollowingFeedRequest) (*feedv1.GetFollowingFeedResponse, error) {
	return &feedv1.GetFollowingFeedResponse{Items: premiumFeedItems()}, nil
}

func (premiumFeed) GetExploreFeed(context.Context, *feedv1.GetExploreFeedRequest) (*feedv1.GetExploreFeedResponse, error) {
	return &feedv1.GetExploreFeedResponse{Items: premiumFeedItems()}, nil
}

// newPremiumEnv is newEnvPatient serving premiumVideos and premiumFeed.
func newPremiumEnv(t *testing.T) *env {
	t.Helper()
	return newEnvServing(t, httpx.ClientAddr{}, downLimits(t), []grpc.DialOption{patientExtras()}, []grpc.DialOption{patientExtras()},
		premiumVideos{}, premiumFeed{})
}

// wantNoPremiumURL fails when the body names an object under premium/ in any form.
func wantNoPremiumURL(t *testing.T, rec *httptest.ResponseRecorder) {
	t.Helper()
	if body := rec.Body.String(); strings.Contains(body, "/premium/") || strings.Contains(body, `"premium/`) {
		t.Errorf("body holds a premium object: %s", body)
	}
}

// TestPremiumVideoGetsPreviewURL: every route that answers a playlist_url gives a premium video
// the public preview's, flagged premium, and never a URL under premium/.
func TestPremiumVideoGetsPreviewURL(t *testing.T) {
	previewURL := mediaBase + "/preview/" + premiumID + "/v1/master.m3u8"
	thumbURL := mediaBase + "/preview/" + premiumID + "/v1/a1/thumbnail.jpg"
	e := newPremiumEnv(t)
	tokenA, tokenC := e.token(t, userA), e.token(t, userC)

	wantPremium := func(t *testing.T, got map[string]any) {
		t.Helper()
		if got["playlist_url"] != previewURL || got["thumbnail_url"] != thumbURL || got["premium"] != true {
			t.Errorf("playlist_url, thumbnail_url, premium = %v, %v, %v; want %s, %s, true",
				got["playlist_url"], got["thumbnail_url"], got["premium"], previewURL, thumbURL)
		}
	}
	single := []struct {
		name, method, path, token string
		status                    int
	}{
		{"get video", http.MethodGet, "/videos/" + premiumID, tokenC, http.StatusOK},
		{"complete upload", http.MethodPost, "/videos/" + premiumID + "/complete", tokenA, http.StatusAccepted},
		{"public video", http.MethodGet, "/public/videos/" + premiumID, "", http.StatusOK},
	}
	for _, tc := range single {
		t.Run(tc.name, func(t *testing.T) {
			rec := e.do(t, tc.method, tc.path, "", tc.token)
			wantStatus(t, rec, tc.status)
			wantNoPremiumURL(t, rec)
			wantPremium(t, decode[map[string]any](t, rec))
		})
	}
	for _, path := range []string{"/me/videos", "/users/" + userA + "/videos", "/feed/following", "/feed/explore"} {
		t.Run(path, func(t *testing.T) {
			rec := e.do(t, http.MethodGet, path, "", tokenA)
			wantStatus(t, rec, http.StatusOK)
			wantNoPremiumURL(t, rec)
			items := decode[struct {
				Items []map[string]any `json:"items"`
			}](t, rec).Items
			if len(items) < 2 {
				t.Fatalf("items = %v", items)
			}
			wantPremium(t, items[0])
			// The regular video of the same page keeps its answer: no premium field.
			if _, ok := items[1]["premium"]; ok || !strings.HasPrefix(items[1]["playlist_url"].(string), mediaBase+"/media/") {
				t.Errorf("regular item = %v", items[1])
			}
			if strings.HasPrefix(path, "/feed/") {
				// A key under premium/ from feed-service gives no URL rather than a private one.
				if leaked := items[2]; leaked["video_id"] != leakedID || leaked["playlist_url"] != "" || leaked["thumbnail_url"] != "" {
					t.Errorf("leaked item = %v, want empty URLs", leaked)
				}
			}
		})
	}
}

// TestPremiumEntitlementTier: GET /videos/{video_id} names the caller's tier, and leaves the
// field out without one, as on a regular video.
func TestPremiumEntitlementTier(t *testing.T) {
	e := newPremiumEnv(t)
	for _, tc := range []struct {
		name, caller, path string
		want               any
	}{
		{"author", userA, "/videos/" + premiumID, "fhd"},
		{"buyer", userB, "/videos/" + premiumID, "sd"},
		{"no entitlement", userC, "/videos/" + premiumID, nil},
		{"regular video", userA, "/videos/" + videoID, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rec := e.do(t, http.MethodGet, tc.path, "", e.token(t, tc.caller))
			wantStatus(t, rec, http.StatusOK)
			got := decode[map[string]any](t, rec)
			if v, ok := got["entitlement_tier"]; tc.want == nil && ok || tc.want != nil && v != tc.want {
				t.Errorf("entitlement_tier = %v (present %v), want %v", v, ok, tc.want)
			}
			if _, ok := got["premium"]; ok != (tc.path != "/videos/"+videoID) {
				t.Errorf("premium present = %v in %v", ok, got)
			}
		})
	}
}

func TestInitUploadForwardsPremium(t *testing.T) {
	for _, tc := range []struct {
		field string
		want  bool
	}{
		{"", false},
		{`,"premium":false`, false},
		{`,"premium":true`, true},
	} {
		t.Run(tc.field, func(t *testing.T) {
			e := newEnv(t)
			body := `{"title":"clip","size_bytes":10,"content_type":"video/mp4"` + tc.field + `}`
			wantStatus(t, e.do(t, http.MethodPost, "/videos", body, e.token(t, userA)), http.StatusCreated)
			if got := e.videos.only(t).req.(*videov1.InitUploadRequest).GetPremium(); got != tc.want {
				t.Errorf("premium = %v, want %v", got, tc.want)
			}
		})
	}
	t.Run("not a boolean", func(t *testing.T) {
		e := newEnv(t)
		body := `{"title":"clip","size_bytes":10,"content_type":"video/mp4","premium":"yes"}`
		rec := e.do(t, http.MethodPost, "/videos", body, e.token(t, userA))
		wantStatus(t, rec, http.StatusBadRequest)
		if p := decodeProblem(t, rec); p.Code != "INVALID_JSON" {
			t.Errorf("code = %q", p.Code)
		}
		if n := e.callCount(); n != 0 {
			t.Errorf("services got %d calls, want 0", n)
		}
	})
}

func TestGrantEntitlement(t *testing.T) {
	for name, tier := range map[string]videov1.Tier{"sd": videov1.Tier_TIER_SD, "hd": videov1.Tier_TIER_HD, "fhd": videov1.Tier_TIER_FHD} {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t)
			rec := e.do(t, http.MethodPut, "/me/entitlements/"+premiumID, `{"tier":"`+name+`"}`, e.token(t, userB))
			wantStatus(t, rec, http.StatusOK)
			wantJSON(t, rec)
			wantSecurityHeaders(t, rec, "no-store")
			got := decode[map[string]string](t, rec)
			want := map[string]string{"video_id": premiumID, "tier": name, "granted_at": "2026-11-15T01:02:03Z"}
			if len(got) != len(want) {
				t.Errorf("body = %v, want %v", got, want)
			}
			for k, v := range want {
				if got[k] != v {
					t.Errorf("%s = %q, want %q", k, got[k], v)
				}
			}
			c := e.videos.only(t)
			if c.method != videov1.VideoService_GrantEntitlement_FullMethodName {
				t.Errorf("method = %s", c.method)
			}
			if req := c.req.(*videov1.GrantEntitlementRequest); req.GetVideoId() != premiumID || req.GetTier() != tier {
				t.Errorf("request = %v", req)
			}
			if v := callers(c.md); !slices.Equal(v, []string{userB}) {
				t.Errorf("caller = %v, want [%s]", v, userB)
			}
		})
	}
}

// TestGrantEntitlementBodies: a body or a tier the gateway cannot send is refused before any call.
func TestGrantEntitlementBodies(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		code       string
	}{
		{"empty", "", "INVALID_JSON"},
		{"not JSON", "tier=sd", "INVALID_JSON"},
		{"unknown field", `{"tier":"sd","user_id":"` + userA + `"}`, "INVALID_JSON"},
		{"not a string", `{"tier":1}`, "INVALID_JSON"},
		{"null", `{"tier":null}`, "INVALID_JSON"},
		{"no tier", `{}`, "INVALID_TIER"},
		{"empty tier", `{"tier":""}`, "INVALID_TIER"},
		{"unknown tier", `{"tier":"uhd"}`, "INVALID_TIER"},
		{"upper case", `{"tier":"SD"}`, "INVALID_TIER"},
		{"enum name", `{"tier":"TIER_SD"}`, "INVALID_TIER"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t)
			rec := e.do(t, http.MethodPut, "/me/entitlements/"+premiumID, tc.body, e.token(t, userB))
			wantStatus(t, rec, http.StatusBadRequest)
			if p := decodeProblem(t, rec); p.Code != tc.code {
				t.Errorf("code = %q, want %q", p.Code, tc.code)
			}
			if n := e.callCount(); n != 0 {
				t.Errorf("services got %d calls, want 0", n)
			}
		})
	}
}

func TestGrantEntitlementErrors(t *testing.T) {
	for _, tc := range []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{"malformed id", grpcerr.New(codes.InvalidArgument, "INVALID_VIDEO_ID", "video_id must be a canonical lowercase UUID"), http.StatusBadRequest, "INVALID_VIDEO_ID"},
		{"invalid tier", grpcerr.New(codes.InvalidArgument, "INVALID_TIER", "tier is invalid"), http.StatusBadRequest, "INVALID_TIER"},
		{"not found", grpcerr.New(codes.NotFound, "VIDEO_NOT_FOUND", "video not found"), http.StatusNotFound, "VIDEO_NOT_FOUND"},
		{"not premium", grpcerr.New(codes.FailedPrecondition, "VIDEO_NOT_PREMIUM", "video is not premium"), http.StatusConflict, "VIDEO_NOT_PREMIUM"},
		{"author", grpcerr.New(codes.FailedPrecondition, "ALREADY_ENTITLED", "the author holds every tier"), http.StatusConflict, "ALREADY_ENTITLED"},
		{"unavailable", status.Error(codes.Unavailable, "video-service is down"), http.StatusServiceUnavailable, "UNAVAILABLE"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			captureLog(t)
			e := newEnv(t)
			e.videos.fail(tc.err)
			rec := e.do(t, http.MethodPut, "/me/entitlements/"+premiumID, `{"tier":"hd"}`, e.token(t, userB))
			wantStatus(t, rec, tc.wantStatus)
			wantSecurityHeaders(t, rec, "no-store")
			if p := decodeProblem(t, rec); p.Code != tc.wantCode {
				t.Errorf("code = %q, want %q", p.Code, tc.wantCode)
			}
			e.videos.only(t)
		})
	}
}

func TestPlayback(t *testing.T) {
	for _, tc := range []struct {
		file, rendition, body string
	}{
		{"master.m3u8", "", fakeMaster},
		{"360p.m3u8", "360p", fakeSigned},
		{"source.m3u8", "source", fakeSigned},
		{"abcdefghijklmnop.m3u8", "abcdefghijklmnop", fakeSigned},
	} {
		t.Run(tc.file, func(t *testing.T) {
			e := newEnv(t)
			rec := e.do(t, http.MethodGet, "/videos/"+premiumID+"/playback/"+tc.file, "", e.token(t, userB))
			wantStatus(t, rec, http.StatusOK)
			if ct := rec.Header().Get("Content-Type"); ct != "application/vnd.apple.mpegurl" {
				t.Errorf("Content-Type = %q", ct)
			}
			wantSecurityHeaders(t, rec, "no-store")
			if v := rec.Header().Get("Content-Disposition"); v != "" {
				t.Errorf("Content-Disposition = %q, want none", v)
			}
			if rec.Body.String() != tc.body {
				t.Errorf("body = %q, want %q", rec.Body.String(), tc.body)
			}
			c := e.videos.only(t)
			if c.method != videov1.VideoService_GetPlaybackPlaylist_FullMethodName {
				t.Errorf("method = %s", c.method)
			}
			if req := c.req.(*videov1.GetPlaybackPlaylistRequest); req.GetVideoId() != premiumID || req.GetRendition() != tc.rendition {
				t.Errorf("request = %v, want rendition %q", req, tc.rendition)
			}
			if v := callers(c.md); !slices.Equal(v, []string{userB}) {
				t.Errorf("caller = %v, want [%s]", v, userB)
			}
		})
	}
}

// TestPlaybackFileOfOtherForm: a file that is neither the master nor a rendition's playlist is a
// 404 without a call, so no path of another form reaches video-service.
func TestPlaybackFileOfOtherForm(t *testing.T) {
	for _, file := range []string{
		"master", "master.m3u8.m3u8", "master.M3U8", "360p", "360p.ts", "index_360p_00000.ts", "360P.m3u8",
		"360_p.m3u8", "360-p.m3u8", ".m3u8", "abcdefghijklmnopq.m3u8", "..%2Fmaster.m3u8", "360p%2F.m3u8",
		"%2E%2E.m3u8", "360p.m3u8%00", "360p.m3u8;x", "master.m3u8%20", "%C3%A9.m3u8",
	} {
		t.Run(file, func(t *testing.T) {
			e := newEnv(t)
			rec := e.do(t, http.MethodGet, "/videos/"+premiumID+"/playback/"+file, "", e.token(t, userB))
			wantStatus(t, rec, http.StatusNotFound)
			wantSecurityHeaders(t, rec, "no-store")
			if p := decodeProblem(t, rec); p.Code != "RENDITION_NOT_FOUND" {
				t.Errorf("code = %q, want RENDITION_NOT_FOUND", p.Code)
			}
			if n := e.callCount(); n != 0 {
				t.Errorf("services got %d calls, want 0", n)
			}
		})
	}
	// A path without a file, or with more segments, is no playback route at all.
	for _, path := range []string{"/playback/", "/playback/a/master.m3u8"} {
		t.Run(path, func(t *testing.T) {
			e := newEnv(t)
			rec := e.do(t, http.MethodGet, "/videos/"+premiumID+path, "", e.token(t, userB))
			wantStatus(t, rec, http.StatusNotFound)
			if n := e.callCount(); n != 0 {
				t.Errorf("services got %d calls, want 0", n)
			}
		})
	}
}

func TestPlaybackErrors(t *testing.T) {
	for _, tc := range []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
		wantDetail string
	}{
		{"malformed id", grpcerr.New(codes.InvalidArgument, "INVALID_VIDEO_ID", "bad id"), http.StatusBadRequest, "INVALID_VIDEO_ID", "bad id"},
		{"not entitled", grpcerr.New(codes.PermissionDenied, "NOT_ENTITLED", "no entitlement"), http.StatusForbidden, "NOT_ENTITLED", "no entitlement"},
		{"above tier", grpcerr.New(codes.PermissionDenied, "RENDITION_NOT_ENTITLED", "above tier"), http.StatusForbidden, "RENDITION_NOT_ENTITLED", "above tier"},
		{"no video", grpcerr.New(codes.NotFound, "VIDEO_NOT_FOUND", "video not found"), http.StatusNotFound, "VIDEO_NOT_FOUND", "video not found"},
		{"no rendition", grpcerr.New(codes.NotFound, "RENDITION_NOT_FOUND", "no rendition"), http.StatusNotFound, "RENDITION_NOT_FOUND", "no rendition"},
		{"not premium", grpcerr.New(codes.FailedPrecondition, "VIDEO_NOT_PREMIUM", "not premium"), http.StatusConflict, "VIDEO_NOT_PREMIUM", "not premium"},
		{"playlist of another form", grpcerr.New(codes.Internal, "PLAYLIST_INVALID", "segment URI premium/x/y"), http.StatusInternalServerError, "INTERNAL", ""},
		{"timeout", status.Error(codes.DeadlineExceeded, "slow"), http.StatusGatewayTimeout, "DEADLINE_EXCEEDED", ""},
	} {
		for _, file := range []string{"master.m3u8", "720p.m3u8"} {
			t.Run(tc.name+" "+file, func(t *testing.T) {
				captureLog(t)
				e := newEnv(t)
				e.videos.fail(tc.err)
				rec := e.do(t, http.MethodGet, "/videos/"+premiumID+"/playback/"+file, "", e.token(t, userC))
				wantStatus(t, rec, tc.wantStatus)
				wantSecurityHeaders(t, rec, "no-store")
				p := decodeProblem(t, rec)
				if p.Code != tc.wantCode || p.Detail != tc.wantDetail {
					t.Errorf("code, detail = %q, %q; want %q, %q", p.Code, p.Detail, tc.wantCode, tc.wantDetail)
				}
				if strings.Contains(rec.Body.String(), "#EXTM3U") {
					t.Errorf("error body holds a playlist: %s", rec.Body.String())
				}
				e.videos.only(t)
			})
		}
	}
}
