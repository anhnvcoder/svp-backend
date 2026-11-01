package server

import (
	"context"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc/codes"

	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
)

// keyedRequest is validRequest with requestID.
func keyedRequest(requestID string) *videov1.InitUploadRequest {
	req := validRequest()
	req.RequestId = requestID
	return req
}

// videosWithRequestID returns how many videos of author carry requestID.
func videosWithRequestID(t *testing.T, author, requestID string) int {
	t.Helper()
	var n int
	err := testPool.QueryRow(t.Context(),
		"SELECT count(*) FROM videos WHERE author_id = $1 AND request_id = $2", author, requestID).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// setStatus moves a video to videoStatus directly, as CompleteUpload, a transcode result or the
// sweep would.
func setStatus(t *testing.T, videoID, videoStatus string) {
	t.Helper()
	if _, err := testPool.Exec(t.Context(), "UPDATE videos SET status = $2 WHERE id = $1", videoID, videoStatus); err != nil {
		t.Fatal(err)
	}
}

// waitingOn waits until n backends of the test database wait for a lock of waitEvent: "advisory"
// for the author lock, "transactionid" for a row another transaction is inserting.
func waitingOn(t *testing.T, waitEvent string, n int) {
	t.Helper()
	eventually(t, waitEvent+" lock waits", func() bool {
		var waiting int
		err := testPool.QueryRow(t.Context(), `SELECT count(*) FROM pg_stat_activity
			WHERE datname = current_database() AND wait_event_type = 'Lock' AND wait_event = $1`, waitEvent).Scan(&waiting)
		if err != nil {
			t.Fatal(err)
		}
		return waiting == n
	})
}

func TestInitUploadWithoutRequestIDCreatesEachTime(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	caller := ids.New()
	first, err := initUpload(t, s, caller, validRequest())
	if err != nil {
		t.Fatal(err)
	}
	second, err := initUpload(t, s, caller, validRequest())
	if err != nil {
		t.Fatal(err)
	}
	if first.GetVideoId() == second.GetVideoId() {
		t.Errorf("two calls returned the same video_id %s", first.GetVideoId())
	}
}

// A repeated call returns the first call's video with a newly signed form for it and stores
// nothing. The request is compared after normalization, as it is stored.
func TestInitUploadRepeatedRequestIDReturnsSameVideo(t *testing.T) {
	needDB(t)
	s, logs := newServer()
	caller, key := ids.New(), ids.New()
	first, err := initUpload(t, s, caller, keyedRequest(key))
	if err != nil {
		t.Fatal(err)
	}
	again := keyedRequest(key)
	again.Title = "  " + again.Title + " "
	again.ContentType = "Video/MP4; codecs=avc1"
	second, err := initUpload(t, s, caller, again)
	if err != nil {
		t.Fatal(err)
	}

	if second.GetVideoId() != first.GetVideoId() {
		t.Errorf("repeated call returned video_id %s, want %s", second.GetVideoId(), first.GetVideoId())
	}
	if n := uploadingCount(t, caller); n != 1 {
		t.Errorf("caller has %d videos UPLOADING, want 1", n)
	}
	if n := videosWithRequestID(t, caller, key); n != 1 {
		t.Errorf("%d videos carry the request_id, want 1", n)
	}
	if got, want := second.GetFormFields()["key"], "uploads/"+first.GetVideoId(); got != want {
		t.Errorf("repeated form key = %q, want %q", got, want)
	}
	if second.GetExpiresAt().AsTime().Before(first.GetExpiresAt().AsTime()) {
		t.Errorf("repeated form expires at %s, before the first one %s", second.GetExpiresAt().AsTime(), first.GetExpiresAt().AsTime())
	}
	if recs := logs.records(t, "video created"); len(recs) != 1 {
		t.Errorf("got %d \"video created\" log lines, want 1", len(recs))
	}
	recs := logs.records(t, "video creation repeated")
	if len(recs) != 1 || recs[0]["video_id"] != first.GetVideoId() || recs[0]["user_id"] != caller {
		t.Errorf("repeat log = %v, want one line with video_id %s and user_id %s", recs, first.GetVideoId(), caller)
	}
	if all := logs.String(); strings.Contains(all, key) || strings.Contains(all, second.GetFormFields()["policy"]) {
		t.Error("logs contain the request_id or the form")
	}
}

func TestInitUploadRequestIDWithOtherRequestIsRejected(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	caller, key := ids.New(), ids.New()
	if _, err := initUpload(t, s, caller, keyedRequest(key)); err != nil {
		t.Fatal(err)
	}
	for name, change := range map[string]func(*videov1.InitUploadRequest){
		"title":        func(r *videov1.InitUploadRequest) { r.Title = "Another title" },
		"size":         func(r *videov1.InitUploadRequest) { r.SizeBytes++ },
		"content type": func(r *videov1.InitUploadRequest) { r.ContentType = "video/webm" },
	} {
		t.Run(name, func(t *testing.T) {
			req := keyedRequest(key)
			change(req)
			_, err := initUpload(t, s, caller, req)
			wantError(t, err, codes.InvalidArgument, ReasonIdempotencyKeyMismatch)
		})
	}
	if n := videosWithRequestID(t, caller, key); n != 1 {
		t.Errorf("%d videos carry the request_id, want 1", n)
	}
}

// Once the video has left UPLOADING the first call cannot be answered again, even with the same
// request.
func TestInitUploadRequestIDOfVideoNotUploading(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	for _, videoStatus := range []string{statusProcessing, statusReady, statusFailed} {
		t.Run(videoStatus, func(t *testing.T) {
			caller, key := ids.New(), ids.New()
			first, err := initUpload(t, s, caller, keyedRequest(key))
			if err != nil {
				t.Fatal(err)
			}
			setStatus(t, first.GetVideoId(), videoStatus)
			_, err = initUpload(t, s, caller, keyedRequest(key))
			wantError(t, err, codes.FailedPrecondition, ReasonVideoNotUploading)
			if n := videosWithRequestID(t, caller, key); n != 1 {
				t.Errorf("%d videos carry the request_id, want 1", n)
			}
		})
	}
}

// createdAgo moves the creation of a video ago into the past, as if the first call had been made
// then, and returns the new created_at.
func createdAgo(t *testing.T, videoID string, ago time.Duration) time.Time {
	t.Helper()
	var created time.Time
	err := testPool.QueryRow(t.Context(),
		"UPDATE videos SET created_at = now() - make_interval(secs => $2) WHERE id = $1 RETURNING created_at",
		videoID, ago.Seconds()).Scan(&created)
	if err != nil {
		t.Fatal(err)
	}
	return created
}

// A repeated call within the first form's window gets a form that ends with that window, not 15
// minutes from the repeat, so repeats never hold more open forms than the limit counts (UP-7).
func TestInitUploadRepeatedRequestIDFormEndsWithFirstWindow(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	caller, key := ids.New(), ids.New()
	first, err := initUpload(t, s, caller, keyedRequest(key))
	if err != nil {
		t.Fatal(err)
	}
	created := createdAgo(t, first.GetVideoId(), 10*time.Minute)

	again, err := initUpload(t, s, caller, keyedRequest(key))
	if err != nil {
		t.Fatalf("repeated call within the window: %v", err)
	}
	if again.GetVideoId() != first.GetVideoId() {
		t.Errorf("repeated call returned video_id %s, want %s", again.GetVideoId(), first.GetVideoId())
	}
	end := created.Add(uploadFormTTL)
	// The policy's expiration has whole seconds, so the form ends in the last second of the window.
	if got := again.GetExpiresAt().AsTime(); got.After(end) || got.Before(end.Add(-time.Second)) {
		t.Errorf("repeated form expires at %s, want in the second before created_at + %s = %s", got, uploadFormTTL, end)
	}
}

// Once the first form's window has ended, or less than a minute of it is left, a repeated call
// gets no form: the first call can no longer be answered again.
func TestInitUploadRepeatedRequestIDAfterWindow(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	for name, ago := range map[string]time.Duration{
		"window ended":        uploadFormTTL + time.Minute,
		"under a minute left": uploadFormTTL - 30*time.Second,
	} {
		t.Run(name, func(t *testing.T) {
			caller, key := ids.New(), ids.New()
			first, err := initUpload(t, s, caller, keyedRequest(key))
			if err != nil {
				t.Fatal(err)
			}
			createdAgo(t, first.GetVideoId(), ago)

			again, err := initUpload(t, s, caller, keyedRequest(key))
			if again != nil {
				t.Errorf("repeated call after the window returned a form expiring at %s", again.GetExpiresAt().AsTime())
			}
			wantError(t, err, codes.FailedPrecondition, ReasonVideoNotUploading)
			if n := videosWithRequestID(t, caller, key); n != 1 {
				t.Errorf("%d videos carry the request_id, want 1", n)
			}
		})
	}
}

// The key belongs to the caller: another user with the same request_id gets a video of their own.
func TestInitUploadRequestIDIsPerAuthor(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	key := ids.New()
	first, err := initUpload(t, s, ids.New(), keyedRequest(key))
	if err != nil {
		t.Fatal(err)
	}
	other := keyedRequest(key)
	other.Title = "Someone else's video"
	second, err := initUpload(t, s, ids.New(), other)
	if err != nil {
		t.Fatal(err)
	}
	if first.GetVideoId() == second.GetVideoId() {
		t.Errorf("two users with one request_id got the same video_id %s", first.GetVideoId())
	}
}

func TestInitUploadInvalidRequestID(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	caller := ids.New()
	for _, key := range []string{"not-a-uuid", "01928C6E-7B3A-7CDE-8F01-23456789ABCD", "{01928c6e-7b3a-7cde-8f01-23456789abcd}", " " + ids.New()} {
		_, err := initUpload(t, s, caller, keyedRequest(key))
		wantError(t, err, codes.InvalidArgument, ReasonInvalidRequestID)
	}
	if n := uploadingCount(t, caller); n != 0 {
		t.Errorf("caller has %d videos UPLOADING after invalid request_ids, want 0", n)
	}
}

// A repeated call is answered before the open uploads are counted, so a client retrying its third
// upload is not refused for the video its own first try created.
func TestInitUploadRepeatedRequestIDAtLimit(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	caller, key := ids.New(), ids.New()
	first, err := initUpload(t, s, caller, keyedRequest(key))
	if err != nil {
		t.Fatal(err)
	}
	for range MaxOpenUploads - 1 {
		if _, err := initUpload(t, s, caller, validRequest()); err != nil {
			t.Fatal(err)
		}
	}

	again, err := initUpload(t, s, caller, keyedRequest(key))
	if err != nil {
		t.Fatalf("repeated call at the limit: %v", err)
	}
	if again.GetVideoId() != first.GetVideoId() {
		t.Errorf("repeated call returned video_id %s, want %s", again.GetVideoId(), first.GetVideoId())
	}
	_, err = initUpload(t, s, caller, keyedRequest(ids.New()))
	wantError(t, err, codes.ResourceExhausted, ReasonTooManyUploads)
}

// Two concurrent calls with one request_id: the author lock orders them, the later one finds the
// video of the earlier, and both answer with it.
func TestConcurrentInitUploadWithOneRequestID(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	caller, key := ids.New(), ids.New()
	ctx := t.Context()

	holder, err := testPool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = holder.Rollback(context.Background()) }()
	if _, err := holder.Exec(ctx,
		"SELECT pg_advisory_xact_lock(hashtextextended('video-upload-author:' || $1::uuid::text, 0))", caller); err != nil {
		t.Fatal(err)
	}
	type result struct {
		videoID string
		err     error
	}
	results := make(chan result, 2)
	for range 2 {
		go func() {
			resp, err := initUpload(t, s, caller, keyedRequest(key))
			results <- result{resp.GetVideoId(), err}
		}()
	}
	waitingOn(t, "advisory", 2)
	if err := holder.Rollback(ctx); err != nil {
		t.Fatal(err)
	}

	var got []string
	for range 2 {
		r := <-results
		if r.err != nil {
			t.Fatalf("concurrent call: %v", r.err)
		}
		got = append(got, r.videoID)
	}
	if got[0] != got[1] {
		t.Errorf("concurrent calls returned video_ids %s and %s, want one", got[0], got[1])
	}
	if n := videosWithRequestID(t, caller, key); n != 1 {
		t.Errorf("%d videos carry the request_id, want 1", n)
	}
}

// A row with the request_id that commits while the call inserts, without the author lock, makes
// the insert fail on the unique index; the call then answers with that row's video.
func TestInitUploadRequestIDUniqueViolationReadsWinner(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	caller, key, winner := ids.New(), ids.New(), ids.New()
	ctx := t.Context()

	other, err := testPool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = other.Rollback(context.Background()) }()
	req := keyedRequest(key)
	if _, err := other.Exec(ctx, `INSERT INTO videos (id, author_id, title, status, size_bytes, content_type, request_id)
		VALUES ($1, $2, $3, 'UPLOADING', $4, $5, $6)`, winner, caller, req.GetTitle(), req.GetSizeBytes(), req.GetContentType(), key); err != nil {
		t.Fatal(err)
	}
	type result struct {
		resp *videov1.InitUploadResponse
		err  error
	}
	done := make(chan result, 1)
	go func() {
		resp, err := initUpload(t, s, caller, req)
		done <- result{resp, err}
	}()
	// The call has not seen the uncommitted row and waits on it in the unique index.
	waitingOn(t, "transactionid", 1)
	if err := other.Commit(ctx); err != nil {
		t.Fatal(err)
	}

	select {
	case r := <-done:
		if r.err != nil {
			t.Fatalf("call that lost the insert: %v", r.err)
		}
		if r.resp.GetVideoId() != winner {
			t.Errorf("video_id = %s, want the committed row's %s", r.resp.GetVideoId(), winner)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("call did not return after the other insert committed")
	}
	if n := videosWithRequestID(t, caller, key); n != 1 {
		t.Errorf("%d videos carry the request_id, want 1", n)
	}
}
