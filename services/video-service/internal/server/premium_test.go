package server

import (
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	mediav1 "github.com/anhnvcoder/svp-backend/gen/go/svp/media/v1"
	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/logx"
	"github.com/anhnvcoder/svp-backend/internal/pgpool"
)

const methodGrantEntitlement = "/svp.video.v1.VideoService/GrantEntitlement"

func grantEntitlement(t *testing.T, s *Server, caller, videoID string, tier videov1.Tier) (*videov1.GrantEntitlementResponse, error) {
	t.Helper()
	return call(t.Context(), caller, methodGrantEntitlement,
		&videov1.GrantEntitlementRequest{VideoId: videoID, Tier: tier}, s.GrantEntitlement)
}

// The keys media-worker publishes for a premium video: the full output under premium/, the
// thumbnail and the preview under preview/.
func premiumPlaylistKeyOf(id string) string {
	return "premium/" + id + "/" + testVersion + "/master.m3u8"
}

func previewPlaylistKeyOf(id string) string {
	return "preview/" + id + "/" + testVersion + "/master.m3u8"
}

func previewThumbnailKeyOf(id string) string {
	return "preview/" + id + "/" + testVersion + "/" + testAttempt + "/thumbnail.jpg"
}

func premiumCompletedEvent(id string) *mediav1.TranscodeEvent {
	return completedWith(id, func(c *mediav1.TranscodeCompleted) {
		c.PlaylistKey = premiumPlaylistKeyOf(id)
		c.ThumbnailKey = previewThumbnailKeyOf(id)
		c.PreviewPlaylistKey = previewPlaylistKeyOf(id)
	})
}

// insertPremium stores a premium video of author in status; a READY one gets its premium keys.
func insertPremium(t *testing.T, author, videoStatus string) string {
	t.Helper()
	id := ids.New()
	insertVideo(t, id, author, videoStatus, false, time.Time{}, time.Now())
	_, err := testPool.Exec(t.Context(), "UPDATE videos SET premium = true WHERE id = $1", id)
	if err == nil && videoStatus == "READY" {
		_, err = testPool.Exec(t.Context(), `UPDATE videos SET duration_ms = 83250, playlist_key = $2, thumbnail_key = $3,
			preview_playlist_key = $4, published_at = now() WHERE id = $1`,
			id, premiumPlaylistKeyOf(id), previewThumbnailKeyOf(id), previewPlaylistKeyOf(id))
	}
	if err != nil {
		t.Fatalf("make video premium: %v", err)
	}
	return id
}

// entitlementRows returns the tier of every entitlement stored for videoID, by user.
func entitlementRows(t *testing.T, videoID string) map[string]string {
	t.Helper()
	rows, err := testPool.Query(t.Context(), "SELECT user_id::text, tier FROM video_entitlements WHERE video_id = $1", videoID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var user, tier string
		if err := rows.Scan(&user, &tier); err != nil {
			t.Fatal(err)
		}
		out[user] = tier
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// wantPremiumFields fails unless v is the READY premium video id with its keys.
func wantPremiumFields(t *testing.T, what string, v *videov1.Video, id string) {
	t.Helper()
	if !v.GetPremium() || v.GetPlaylistKey() != premiumPlaylistKeyOf(id) ||
		v.GetThumbnailKey() != previewThumbnailKeyOf(id) || v.GetPreviewPlaylistKey() != previewPlaylistKeyOf(id) {
		t.Errorf("%s = %v, want the premium video with its premium and preview keys", what, v)
	}
}

// A premium upload is stored premium and announced so in video.uploaded; a regular one is not.
func TestInitUploadPremiumReachesVideoUploaded(t *testing.T) {
	needDB(t)
	for _, isPremium := range []bool{true, false} {
		s, storage, _ := newServerWithStorage()
		author := ids.New()
		req := validRequest()
		req.Premium = isPremium
		resp, err := initUpload(t, s, author, req)
		if err != nil {
			t.Fatal(err)
		}
		id := resp.GetVideoId()
		storage.put(id, req.GetSizeBytes(), "video/mp4")
		done, err := completeUpload(t.Context(), t, s, author, id)
		if err != nil {
			t.Fatal(err)
		}
		if done.GetVideo().GetPremium() != isPremium || loadVideo(t, id).Premium != isPremium {
			t.Errorf("premium %v: CompleteUpload returned %v, stored %v", isPremium, done.GetVideo().GetPremium(), loadVideo(t, id).Premium)
		}
		rows := outboxRows(t, id)
		if len(rows) != 1 {
			t.Fatalf("got %d outbox rows, want 1", len(rows))
		}
		var ev videov1.VideoEvent
		if err := proto.Unmarshal(rows[0].payload, &ev); err != nil {
			t.Fatal(err)
		}
		if got := ev.GetVideoUploaded().GetPremium(); got != isPremium {
			t.Errorf("video_uploaded.premium = %v, want %v", got, isPremium)
		}
	}
}

// A request_id reused with another premium flag is another request.
func TestInitUploadRequestIDWithOtherPremiumIsRejected(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author, key := ids.New(), ids.New()
	if _, err := initUpload(t, s, author, keyedRequest(key)); err != nil {
		t.Fatal(err)
	}
	req := keyedRequest(key)
	req.Premium = true
	_, err := initUpload(t, s, author, req)
	wantError(t, err, codes.InvalidArgument, ReasonIdempotencyKeyMismatch)
}

func TestTranscodeCompletedPremiumStoresPreviewAndEmitsIt(t *testing.T) {
	needDB(t)
	s, _, _ := newServerWithStorage()
	author := ids.New()
	id := insertPremium(t, author, "PROCESSING")

	if err := handleTranscode(t.Context(), s, transcodeRecord(id, premiumCompletedEvent(id))); err != nil {
		t.Fatal(err)
	}
	v := loadVideo(t, id)
	if v.Status != "READY" || v.PreviewPlaylistKey == nil || *v.PreviewPlaylistKey != previewPlaylistKeyOf(id) {
		t.Errorf("stored video = %+v, want READY with the preview playlist", v)
	}
	rows := outboxRows(t, id)
	if len(rows) != 1 {
		t.Fatalf("got %d outbox rows, want 1", len(rows))
	}
	var ev videov1.VideoEvent
	if err := proto.Unmarshal(rows[0].payload, &ev); err != nil {
		t.Fatal(err)
	}
	ready := ev.GetVideoReady()
	if !ready.GetPremium() || ready.GetPreviewPlaylistKey() != previewPlaylistKeyOf(id) ||
		ready.GetPlaylistKey() != premiumPlaylistKeyOf(id) || ready.GetThumbnailKey() != previewThumbnailKeyOf(id) {
		t.Errorf("video_ready = %v, want premium with the premium and preview keys", ready)
	}

	resp, err := getVideo(t, s, author, id)
	if err != nil {
		t.Fatal(err)
	}
	wantPremiumFields(t, "GetVideo", resp.GetVideo(), id)
	public, err := getPublicVideo(t, s, "", id)
	if err != nil {
		t.Fatal(err)
	}
	wantPremiumFields(t, "GetPublicVideo", public.GetVideo(), id)
	list, err := listAuthorVideos(t, s, ids.New(), &videov1.ListAuthorVideosRequest{AuthorId: author})
	if err != nil {
		t.Fatal(err)
	}
	if len(list.GetVideos()) != 1 {
		t.Fatalf("ListAuthorVideos returned %d videos, want 1", len(list.GetVideos()))
	}
	wantPremiumFields(t, "ListAuthorVideos", list.GetVideos()[0], id)
}

// Keys under the wrong prefixes for the video's flag go to the dead-letter topic and leave the
// video PROCESSING: above all a premium video whose output is under the public media/.
func TestTranscodeCompletedWrongPrefixGoesToDeadLetter(t *testing.T) {
	needDB(t)
	brokers := transcodeCluster(t, 1)
	s, storage, _ := newServerWithStorage()

	cases := []struct {
		name    string
		premium bool
		event   func(id string) *mediav1.TranscodeEvent
	}{
		{"premium video with keys under media/", true, completedEvent},
		{"premium video with its preview under media/", true, func(id string) *mediav1.TranscodeEvent {
			return completedWith(id, func(c *mediav1.TranscodeCompleted) {
				c.PlaylistKey = premiumPlaylistKeyOf(id)
				c.ThumbnailKey = previewThumbnailKeyOf(id)
				c.PreviewPlaylistKey = "media/" + id + "/" + testVersion + "/master.m3u8"
			})
		}},
		{"premium video without a preview", true, func(id string) *mediav1.TranscodeEvent {
			ev := premiumCompletedEvent(id)
			ev.GetTranscodeCompleted().PreviewPlaylistKey = ""
			return ev
		}},
		{"premium video with its thumbnail under premium/", true, func(id string) *mediav1.TranscodeEvent {
			ev := premiumCompletedEvent(id)
			ev.GetTranscodeCompleted().ThumbnailKey = "premium/" + id + "/" + testVersion + "/thumbnail.jpg"
			return ev
		}},
		{"premium video with its full playlist under preview/", true, func(id string) *mediav1.TranscodeEvent {
			ev := premiumCompletedEvent(id)
			ev.GetTranscodeCompleted().PlaylistKey = previewPlaylistKeyOf(id)
			return ev
		}},
		{"premium preview of another video", true, func(id string) *mediav1.TranscodeEvent {
			ev := premiumCompletedEvent(id)
			ev.GetTranscodeCompleted().PreviewPlaylistKey = previewPlaylistKeyOf(ids.New())
			return ev
		}},
		{"premium preview climbing out with ..", true, func(id string) *mediav1.TranscodeEvent {
			ev := premiumCompletedEvent(id)
			ev.GetTranscodeCompleted().PreviewPlaylistKey = "preview/" + id + "/../x"
			return ev
		}},
		{"regular video with keys under premium/", false, premiumCompletedEvent},
		{"regular video with a preview", false, func(id string) *mediav1.TranscodeEvent {
			return completedWith(id, func(c *mediav1.TranscodeCompleted) { c.PreviewPlaylistKey = previewPlaylistKeyOf(id) })
		}},
	}
	h := &handled{}
	startTranscodeConsumer(t, s, brokers, time.Millisecond, h)

	videoIDs := make([]string, len(cases))
	var rs []*kgo.Record
	for i, c := range cases {
		if c.premium {
			videoIDs[i] = insertPremium(t, ids.New(), "PROCESSING")
		} else {
			videoIDs[i] = newVideo(t, "PROCESSING")
		}
		r := transcodeRecord(videoIDs[i], c.event(videoIDs[i]))
		r.Headers = []kgo.RecordHeader{{Key: "test-case", Value: []byte(c.name)}}
		rs = append(rs, r)
	}
	// One partition: once the last record is handled, every earlier one is settled.
	last := insertPremium(t, ids.New(), "PROCESSING")
	rs = append(rs, transcodeRecord(last, premiumCompletedEvent(last)))
	produce(t, brokers, rs...)
	eventually(t, "the last record to be handled", func() bool { return h.done(last) })

	dead := readTopic(t, brokers, TopicMediaTranscodes+kafkax.DLQSuffix, "", len(cases))
	byCase := map[string]*kgo.Record{}
	for _, r := range dead {
		byCase[headerValue(r, "test-case")] = r
	}
	for i, c := range cases {
		r, ok := byCase[c.name]
		switch {
		case !ok:
			t.Errorf("%s: not in the dead-letter topic", c.name)
		case headerValue(r, kafkax.HeaderDLQReason) != kafkax.ReasonPermanent:
			t.Errorf("%s: dlq-reason = %q, want permanent", c.name, headerValue(r, kafkax.HeaderDLQReason))
		}
		wantUnchanged(t, videoIDs[i], "PROCESSING")
	}
	if len(dead) != len(cases) {
		t.Errorf("got %d dead letters, want %d", len(dead), len(cases))
	}
	if got := loadVideo(t, last).Status; got != "READY" {
		t.Errorf("premium video with the right keys is %s, want READY", got)
	}
	wantDeletes(t, storage)
}

// A failed premium video loses its upload and everything under its premium/ and preview/
// prefixes, and nothing under media/; a redelivery deletes the same again.
func TestTranscodeFailedPremiumDeletesItsPrefixes(t *testing.T) {
	needDB(t)
	s, storage, _ := newServerWithStorage()
	id := insertPremium(t, ids.New(), "PROCESSING")
	r := transcodeRecord(id, failedEvent(id))
	want := []string{"uploads/" + id, "premium/" + id + "/", "preview/" + id + "/"}

	if err := handleTranscode(t.Context(), s, r); err != nil {
		t.Fatal(err)
	}
	wantDeletes(t, storage, want...)
	if err := handleTranscode(t.Context(), s, r); err != nil {
		t.Fatal(err)
	}
	wantDeletes(t, storage, append(want, want...)...)
}

func TestGetVideoEntitlementTier(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author, buyer, other := ids.New(), ids.New(), ids.New()
	id := insertPremium(t, author, "READY")
	regular := newVideo(t, "READY")
	if _, err := grantEntitlement(t, s, buyer, id, videov1.Tier_TIER_HD); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		name, caller, video string
		want                videov1.Tier
	}{
		{"author of a premium video", author, id, videov1.Tier_TIER_FHD},
		{"buyer", buyer, id, videov1.Tier_TIER_HD},
		{"user without an entitlement", other, id, videov1.Tier_TIER_UNSPECIFIED},
		{"author of a regular video", loadVideo(t, regular).AuthorID.String(), regular, videov1.Tier_TIER_UNSPECIFIED},
		{"anyone on a regular video", other, regular, videov1.Tier_TIER_UNSPECIFIED},
	} {
		resp, err := getVideo(t, s, tc.caller, tc.video)
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if got := resp.GetEntitlementTier(); got != tc.want {
			t.Errorf("%s: entitlement_tier = %s, want %s", tc.name, got, tc.want)
		}
	}

	// The author sees every tier while the video is still being processed, too.
	processing := insertPremium(t, author, "PROCESSING")
	resp, err := getVideo(t, s, author, processing)
	if err != nil {
		t.Fatal(err)
	}
	if got := resp.GetEntitlementTier(); got != videov1.Tier_TIER_FHD || !resp.GetVideo().GetPremium() {
		t.Errorf("author's PROCESSING premium video: tier %s, premium %v; want TIER_FHD and true", got, resp.GetVideo().GetPremium())
	}
}

func TestGrantEntitlementRecordsAndOverwritesTier(t *testing.T) {
	needDB(t)
	s, logs := newServer()
	buyer := ids.New()
	id := insertPremium(t, ids.New(), "READY")

	before := time.Now()
	resp, err := grantEntitlement(t, s, buyer, id, videov1.Tier_TIER_SD)
	if err != nil {
		t.Fatal(err)
	}
	e := resp.GetEntitlement()
	if e.GetVideoId() != id || e.GetTier() != videov1.Tier_TIER_SD || e.GetGrantedAt().AsTime().Before(before.Add(-time.Second)) {
		t.Errorf("entitlement = %v, want TIER_SD on %s granted now", e, id)
	}

	// A repeated purchase changes the tier of the one entitlement, upward or downward.
	for _, tier := range []videov1.Tier{videov1.Tier_TIER_FHD, videov1.Tier_TIER_FHD, videov1.Tier_TIER_HD} {
		resp, err := grantEntitlement(t, s, buyer, id, tier)
		if err != nil {
			t.Fatal(err)
		}
		if got := resp.GetEntitlement().GetTier(); got != tier {
			t.Errorf("tier after granting %s = %s", tier, got)
		}
	}
	if rows := entitlementRows(t, id); len(rows) != 1 || rows[buyer] != "hd" {
		t.Errorf("entitlements = %v, want one hd for %s", rows, buyer)
	}
	recs := logs.records(t, "entitlement granted")
	if len(recs) != 4 || recs[3]["tier"] != "hd" || recs[3]["user_id"] != buyer || recs[3]["video_id"] != id {
		t.Errorf("\"entitlement granted\" log lines = %v, want 4, the last with tier hd, user and video", recs)
	}
}

func TestGrantEntitlementRefused(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author, buyer := ids.New(), ids.New()
	premium := insertPremium(t, author, "READY")
	regular := newVideo(t, "READY")

	for _, tc := range []struct {
		name, caller, video string
		tier                videov1.Tier
		code                codes.Code
		reason              string
	}{
		{"regular video", buyer, regular, videov1.Tier_TIER_SD, codes.FailedPrecondition, ReasonVideoNotPremium},
		{"missing video", buyer, ids.New(), videov1.Tier_TIER_SD, codes.NotFound, ReasonVideoNotFound},
		{"author", author, premium, videov1.Tier_TIER_FHD, codes.FailedPrecondition, ReasonAlreadyEntitled},
		{"unspecified tier", buyer, premium, videov1.Tier_TIER_UNSPECIFIED, codes.InvalidArgument, ReasonInvalidTier},
		{"unknown tier", buyer, premium, videov1.Tier(9), codes.InvalidArgument, ReasonInvalidTier},
		{"invalid video_id", buyer, strings.ToUpper(premium), videov1.Tier_TIER_SD, codes.InvalidArgument, ReasonInvalidVideoID},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := grantEntitlement(t, s, tc.caller, tc.video, tc.tier)
			wantError(t, err, tc.code, tc.reason)
		})
	}
	// A premium video not READY yet, even to its author, looks like a missing one.
	for _, st := range []string{"UPLOADING", "PROCESSING", "FAILED"} {
		id := insertPremium(t, author, st)
		for _, caller := range []string{buyer, author} {
			_, err := grantEntitlement(t, s, caller, id, videov1.Tier_TIER_SD)
			wantSameAsMissing(t, st+" premium video", err)
		}
	}
	if rows := entitlementRows(t, premium); len(rows) != 0 {
		t.Errorf("entitlements after refused grants = %v, want none", rows)
	}
}

// An entitlement is the caller's own: buying never writes another user's entitlement, and
// GetVideo never shows one.
func TestEntitlementBelongsToCaller(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	userA, userB := ids.New(), ids.New()
	id := insertPremium(t, ids.New(), "READY")

	if _, err := grantEntitlement(t, s, userB, id, videov1.Tier_TIER_FHD); err != nil {
		t.Fatal(err)
	}
	resp, err := getVideo(t, s, userA, id)
	if err != nil {
		t.Fatal(err)
	}
	if got := resp.GetEntitlementTier(); got != videov1.Tier_TIER_UNSPECIFIED {
		t.Errorf("user A sees tier %s from user B's entitlement", got)
	}
	if _, err := grantEntitlement(t, s, userA, id, videov1.Tier_TIER_SD); err != nil {
		t.Fatal(err)
	}
	if rows := entitlementRows(t, id); len(rows) != 2 || rows[userA] != "sd" || rows[userB] != "fhd" {
		t.Errorf("entitlements = %v, want sd for A and fhd for B", rows)
	}
	resp, err = getVideo(t, s, userB, id)
	if err != nil {
		t.Fatal(err)
	}
	if got := resp.GetEntitlementTier(); got != videov1.Tier_TIER_FHD {
		t.Errorf("user B's tier after A's purchase = %s, want TIER_FHD", got)
	}
}

// Concurrent purchases of one user and video leave one entitlement with one of their tiers.
func TestConcurrentGrantEntitlementKeepsOneRow(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	buyer := ids.New()
	id := insertPremium(t, ids.New(), "READY")

	tiers := []videov1.Tier{videov1.Tier_TIER_SD, videov1.Tier_TIER_HD, videov1.Tier_TIER_FHD, videov1.Tier_TIER_SD}
	errs := make([]error, len(tiers))
	var wg sync.WaitGroup
	for i, tier := range tiers {
		wg.Go(func() { _, errs[i] = grantEntitlement(t, s, buyer, id, tier) })
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Errorf("grant %d: %v", i, err)
		}
	}
	rows := entitlementRows(t, id)
	if len(rows) != 1 || (rows[buyer] != "sd" && rows[buyer] != "hd" && rows[buyer] != "fhd") {
		t.Fatalf("entitlements = %v, want one row for %s", rows, buyer)
	}
	// The row holds the tier of the write that committed last: a later purchase still wins.
	if _, err := grantEntitlement(t, s, buyer, id, videov1.Tier_TIER_HD); err != nil {
		t.Fatal(err)
	}
	if rows := entitlementRows(t, id); rows[buyer] != "hd" {
		t.Errorf("tier after the last purchase = %q, want hd", rows[buyer])
	}
}

func TestGrantEntitlementWithoutCallerOrDatabase(t *testing.T) {
	s, _ := newServer()
	_, err := grantEntitlement(t, s, "", ids.New(), videov1.Tier_TIER_SD)
	if status.Code(err) != codes.Unauthenticated {
		t.Errorf("GrantEntitlement without a token = %v, want UNAUTHENTICATED", err)
	}

	needDB(t)
	// Opened as main opens its pool.
	closed, err := pgpool.New(t.Context(), testPool.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	closed.Close()
	logs := &logBuffer{}
	broken := New(closed, newFakeStorage(), nil, slog.New(logx.NewHandler(slog.NewJSONHandler(logs, nil))))
	_, err = grantEntitlement(t, broken, ids.New(), ids.New(), videov1.Tier_TIER_SD)
	if status.Code(err) != codes.Internal || status.Convert(err).Message() != "internal error" {
		t.Errorf("error = %v, want INTERNAL with message %q", err, "internal error")
	}
}
