package mediaconvert

import (
	"context"
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/mediaconvert"
	"github.com/aws/aws-sdk-go-v2/service/mediaconvert/types"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	"google.golang.org/protobuf/types/known/durationpb"

	mediav1 "github.com/anhnvcoder/svp-backend/gen/go/svp/media/v1"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/transcode"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/worker"
)

const immutable = "max-age=31536000, immutable"

func failure(id string, reason mediav1.TranscodeFailureReason, detail string) *mediav1.TranscodeEvent {
	return &mediav1.TranscodeEvent{Event: &mediav1.TranscodeEvent_TranscodeFailed{
		TranscodeFailed: &mediav1.TranscodeFailed{VideoId: id, Reason: reason, Detail: detail},
	}}
}

// jobFailed is the transcode.failed of job of video id ending with code.
func jobFailed(id, job string, reason mediav1.TranscodeFailureReason, code int) *mediav1.TranscodeEvent {
	return failure(id, reason, fmt.Sprintf("mediaconvert job %s: error %d: error of the fake", job, code))
}

// attemptOf returns the attempt of job.
func (e *env) attemptOf(t *testing.T, job string) string {
	t.Helper()
	return e.mc.job(t, job).UserMetadata[metaAttempt]
}

// completedFor is the transcode.completed of the reference clip whose job ran as attempt.
func completedFor(id, version, attempt string) *mediav1.TranscodeEvent {
	prefix := "media/" + id + "/" + version + "/"
	return &mediav1.TranscodeEvent{Event: &mediav1.TranscodeEvent_TranscodeCompleted{
		TranscodeCompleted: &mediav1.TranscodeCompleted{
			VideoId:      id,
			PlaylistKey:  prefix + "master.m3u8",
			ThumbnailKey: prefix + attempt + "/thumbnail.jpg",
			// The sum of #EXTINF of the stored playlist, not the 6000 ms the job reports.
			Duration: durationpb.New(6020 * time.Millisecond),
			Renditions: []*mediav1.Rendition{
				{Name: "360p", Width: 360, Height: 640, BitrateBps: 800_000},
				{Name: "720p", Width: 720, Height: 1280, BitrateBps: 2_500_000},
				{Name: "1080p", Width: 1080, Height: 1920, BitrateBps: 5_000_000},
			},
		},
	}}
}

func noMaster(t *testing.T, e *env, id, version string) {
	t.Helper()
	if m := e.store.get("media/" + id + "/" + version + "/master.m3u8"); m != nil {
		t.Errorf("master created:\n%s", m)
	}
}

// The whole path: video.uploaded probes and creates one job and records it, publishing nothing;
// the job's COMPLETE gives every object of the attempt the headers of serve, makes the frame
// capture the thumbnail, creates the master and publishes the result read back from storage.
func TestUploadedThenCompleteGivesResult(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	r, id, version := uploadedRecord(t)
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	jobs := e.mc.jobIDs()
	if len(jobs) != 1 || e.recordedJob(t, id, version) != jobs[0] {
		t.Fatalf("jobs %v, record %s", jobs, e.recordOf(id, version))
	}
	if want := fmt.Sprintf(`{"attempt":"%s","job_id":"%s"}`, e.attemptOf(t, jobs[0]), jobs[0]); string(e.recordOf(id, version)) != want {
		t.Errorf("record = %s, want %s", e.recordOf(id, version), want)
	}
	if typ := e.store.types[recordKey(id, version)]; typ != "application/json" {
		t.Errorf("record content type %q", typ)
	}
	if n := len(e.events(t)); n != 0 {
		t.Fatalf("%d events published while the job runs", n)
	}

	e.mc.complete(t, jobs[0])
	if !e.message(t, jobs[0], types.JobStatusComplete) {
		t.Fatal("COMPLETE message not done with")
	}
	attempt := e.attemptOf(t, jobs[0])
	sameResult(t, e.events(t), completedFor(id, version, attempt))

	prefix := "media/" + id + "/" + version + "/"
	keys := e.store.keys(prefix)
	for _, k := range keys {
		want := map[string]string{".ts": "video/mp2t", ".m3u8": "application/vnd.apple.mpegurl", ".jpg": "image/jpeg"}[k[strings.LastIndex(k, "."):]]
		if e.store.types[k] != want || e.store.caches[k] != immutable {
			t.Errorf("%s: Content-Type %q, Cache-Control %q", k, e.store.types[k], e.store.caches[k])
		}
		if k != prefix+"master.m3u8" && !strings.HasPrefix(k, prefix+attempt+"/") {
			t.Errorf("%s outside the attempt directory", k)
		}
	}
	if string(e.store.get(prefix+attempt+"/thumbnail.jpg")) != "jpeg" {
		t.Error("frame capture not copied to thumbnail.jpg")
	}
	m, err := transcode.ParseMaster(e.store.get(prefix + "master.m3u8"))
	if err != nil || m.Attempt != attempt {
		t.Errorf("master: %+v, %v", m, err)
	}
	if entries, _ := os.ReadDir(e.workDir); len(entries) != 0 {
		t.Errorf("work directory not cleaned: %v", entries)
	}
}

// Lost response, retried: CreateJob makes J1 but the answer is lost; the retry makes and records
// J2. J1's event settles J2 (still running: nothing), and J2's COMPLETE publishes J2's attempt.
func TestLostResponseThenRetryRecordsTheSecondJob(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	r, id, version := uploadedRecord(t)
	e.mc.lose = 1
	if err := e.handle(t, r); err == nil {
		t.Fatal("first try succeeded although CreateJob failed")
	}
	if e.recordOf(id, version) != nil {
		t.Fatal("record written without a job")
	}
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	jobs := e.mc.jobIDs()
	j1, j2 := jobs[0], jobs[1]
	if e.recordedJob(t, id, version) != j2 {
		t.Fatalf("record names %s, want %s", e.recordedJob(t, id, version), j2)
	}
	e.mc.complete(t, j1)
	if !e.message(t, j1, types.JobStatusComplete) {
		t.Error("message of J1 not done with")
	}
	noMaster(t, e, id, version)
	if n := len(e.events(t)); n != 0 {
		t.Fatalf("%d events from J1", n)
	}
	e.mc.complete(t, j2)
	e.message(t, j2, types.JobStatusComplete)
	sameResult(t, e.events(t), completedFor(id, version, e.attemptOf(t, j2)))
}

// Lost response, event first: J1's COMPLETE records J1 before the retry; the retry's J2 meets
// the record and is a stray, and the result is J1's.
func TestLostResponseEventFirstKeepsTheFirstJob(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	r, id, version := uploadedRecord(t)
	e.mc.lose = 1
	if err := e.handle(t, r); err == nil {
		t.Fatal("first try succeeded although CreateJob failed")
	}
	j1 := e.mc.jobIDs()[0]
	e.mc.complete(t, j1)
	if !e.message(t, j1, types.JobStatusComplete) {
		t.Fatal("message of J1 not done with")
	}
	want := completedFor(id, version, e.attemptOf(t, j1))
	record := string(e.recordOf(id, version))

	// The record already decides the version: the retry neither probes nor creates a job.
	probes, creates := e.mc.calls()
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	if p, c := e.mc.calls(); p != probes || c != creates {
		t.Errorf("retry called Probe %d and CreateJob %d more times", p-probes, c-creates)
	}

	// A retry that read no record before the event came: its J2 meets the record of J1.
	j2 := e.raceRecord(t, r, id, version)
	if string(e.recordOf(id, version)) != record {
		t.Errorf("record = %s, want J1's %s", e.recordOf(id, version), record)
	}
	e.mc.complete(t, j2)
	e.message(t, j2, types.JobStatusComplete)
	sameResult(t, e.events(t), want)
}

// raceRecord runs one try at r that reads no record, as one that read storage before another
// path wrote it, and returns the job that try creates.
func (e *env) raceRecord(t *testing.T, r *kgo.Record, id, version string) string {
	t.Helper()
	key := recordKey(id, version)
	saved := e.store.get(key)
	e.store.mu.Lock()
	delete(e.store.objects, key)
	e.store.mu.Unlock()
	e.mc.mu.Lock()
	e.mc.beforeCreate = func() {
		e.store.mu.Lock()
		e.store.objects[key] = saved
		e.store.mu.Unlock()
	}
	e.mc.mu.Unlock()
	defer func() {
		e.mc.mu.Lock()
		e.mc.beforeCreate = nil
		e.mc.mu.Unlock()
	}()
	before := e.mc.jobIDs()
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	for _, j := range e.mc.jobIDs() {
		if !slices.Contains(before, j) {
			return j
		}
	}
	t.Fatal("the try created no job")
	return ""
}

// A stale caller after a rebalance: A reads no record and stalls in CreateJob; meanwhile B
// creates, records and fails J_B. A's J_A meets B's record, and J_A completing changes nothing:
// no master, every event of the version is B's transcode.failed.
func TestStaleCallerAfterRebalance(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	r, id, version := uploadedRecord(t)
	var jobB string
	var fired atomic.Bool
	e.mc.beforeCreate = func() {
		if fired.Swap(true) {
			return
		}
		func() {
			// B, on the member that took the partition, runs to its end while A waits.
			b := e.bridge()
			if err := b.Handle(t.Context(), r, kafkax.Attempt{Number: 1}); err != nil {
				t.Error(err)
			}
			jobB = e.recordedJob(t, id, version)
			e.mc.fail(t, jobB, 1010)
			body := stateChangeOf(jobB, types.JobStatusError)
			if !b.HandleMessage(t.Context(), &body) {
				t.Error("ERROR of J_B not done with")
			}
		}()
	}
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	jobs := e.mc.jobIDs()
	jobA := jobs[slices.IndexFunc(jobs, func(j string) bool { return j != jobB })]
	e.mc.complete(t, jobA)
	if !e.message(t, jobA, types.JobStatusComplete) {
		t.Error("COMPLETE of J_A not done with")
	}
	noMaster(t, e, id, version)
	evs := e.events(t)
	sameResult(t, evs, jobFailed(id, jobB, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT, 1010))
	if len(evs) != 3 {
		t.Errorf("%d events, want B's, A's replay and J_A's message", len(evs))
	}
}

// A request that ends after the last read: the last try's CreateJob times out, so the version is
// recorded RETRIES_EXHAUSTED and failed; the job created anyway completes later and changes
// nothing. When even that record cannot be written, nothing is published.
func TestRequestFinishedAfterLastTry(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	r, id, version := uploadedRecord(t)
	e.mc.lose = 1
	if err := e.b.Handle(t.Context(), r, kafkax.Attempt{Number: worker.MaxAttempts, Last: true}); err != nil {
		t.Fatal(err)
	}
	want := failure(id, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_RETRIES_EXHAUSTED, recordedDetail)
	if got := string(e.recordOf(id, version)); got != `{"reason":"TRANSCODE_FAILURE_REASON_RETRIES_EXHAUSTED"}` {
		t.Errorf("record = %s", got)
	}
	late := e.mc.jobIDs()[0]
	e.mc.complete(t, late)
	if !e.message(t, late, types.JobStatusComplete) {
		t.Error("message of the late job not done with")
	}
	noMaster(t, e, id, version)
	sameResult(t, e.events(t), want)

	r2, id2, version2 := uploadedRecord(t)
	e.mc.lose = 1
	e.store.failCreate = func(key string) bool { return key == recordKey(id2, version2) }
	err := e.b.Handle(t.Context(), r2, kafkax.Attempt{Number: worker.MaxAttempts, Last: true})
	if err == nil || errors.Is(err, context.Canceled) {
		t.Fatalf("Handle() = %v, want the error that sends the record to the dead-letter topic", err)
	}
	for _, ev := range e.events(t) {
		if ev.GetTranscodeFailed().GetVideoId() == id2 || ev.GetTranscodeCompleted().GetVideoId() == id2 {
			t.Errorf("published %v while the result is undecided", ev)
		}
	}
}

// Through the consumer: a record whose result cannot be recorded on the last try goes to the
// dead-letter topic, with nothing published.
func TestConsumerDeadLettersAnUndecidedResult(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	r, id, version := uploadedRecord(t)
	e.mc.probeErr = errors.New("operation error MediaConvert: Probe, https response error StatusCode: 503")
	e.store.failCreate = func(key string) bool { return key == recordKey(id, version) }
	cfg := e.b.ConsumerConfig(e.brokers)
	cfg.MaxAttempts, cfg.BackoffBase, cfg.BackoffMax = 2, time.Millisecond, 2*time.Millisecond
	c, err := kafkax.NewConsumer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- c.Run(ctx) }()
	defer func() {
		cancel()
		if err := <-done; err != nil {
			t.Errorf("consumer: %v", err)
		}
	}()
	if err := kafkax.Produce(t.Context(), e.client, r); err != nil {
		t.Fatal(err)
	}
	cl, err := kafkax.NewClient(e.brokers, "dlq-reader", kgo.ConsumeTopics(worker.InputTopic+kafkax.DLQSuffix))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	rctx, rcancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer rcancel()
	var dead []*kgo.Record
	for len(dead) == 0 && rctx.Err() == nil {
		dead = append(dead, cl.PollFetches(rctx).Records()...)
	}
	if len(dead) != 1 || string(dead[0].Key) != id {
		t.Fatalf("dead-letter records = %v, want the video.uploaded of %s", dead, id)
	}
	if n := len(e.events(t)); n != 0 {
		t.Errorf("%d events published", n)
	}
}

// Repeats are normal: two jobs ending in ERROR, a COMPLETE delivered twice, a message settled
// again after a crash between publish and DeleteMessage all publish the same result.
func TestRepeatsPublishTheSameResult(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	r, id, _ := uploadedRecord(t)
	e.mc.lose = 1
	_ = e.handle(t, r)
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	jobs := e.mc.jobIDs()
	stray, recorded := jobs[0], jobs[1]
	e.mc.fail(t, stray, 1030)
	e.mc.fail(t, recorded, 1999)
	want := jobFailed(id, recorded, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_RETRIES_EXHAUSTED, 1999)
	for _, j := range []string{stray, recorded, recorded} {
		if !e.message(t, j, types.JobStatusError) {
			t.Errorf("ERROR of %s not done with", j)
		}
	}
	sameResult(t, e.events(t), want)

	r2, id2, version2 := uploadedRecord(t)
	if err := e.handle(t, r2); err != nil {
		t.Fatal(err)
	}
	job := e.recordedJob(t, id2, version2)
	e.mc.complete(t, job)
	// Delivered twice, the second as if the first crashed after publishing.
	e.message(t, job, types.JobStatusComplete)
	e.message(t, job, types.JobStatusComplete)
	if err := e.handle(t, r2); err != nil {
		t.Fatal(err)
	}
	var completed []*mediav1.TranscodeEvent
	for _, ev := range e.events(t) {
		if ev.GetTranscodeCompleted().GetVideoId() == id2 {
			completed = append(completed, ev)
		}
	}
	if len(completed) != 3 {
		t.Errorf("%d results for the twice-delivered COMPLETE and the replay, want 3", len(completed))
	}
	sameResult(t, completed, completedFor(id2, version2, e.attemptOf(t, job)))
}

// After a restart the bridge may see only SQS messages, no video.uploaded: the message records
// its job and settles the version on its own.
func TestRestartWithOnlyTheMessage(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	r, id, version := uploadedRecord(t)
	e.mc.lose = 1
	_ = e.handle(t, r) // the job exists, nothing is recorded, and the record is never retried
	job := e.mc.jobIDs()[0]
	e.mc.complete(t, job)
	e.b = e.bridge()
	if !e.message(t, job, types.JobStatusComplete) {
		t.Fatal("message not done with")
	}
	if e.recordedJob(t, id, version) != job {
		t.Errorf("record = %s, want %s", e.recordOf(id, version), job)
	}
	sameResult(t, e.events(t), completedFor(id, version, e.attemptOf(t, job)))
}

// video.uploaded delivered again settles what is recorded, never probing or creating a job.
func TestUploadedAgainSettlesTheRecord(t *testing.T) {
	t.Parallel()
	e := newEnv(t)

	// A recorded reason.
	r, id, _ := uploadedRecord(t)
	e.mc.probe = probeOf(1080, 1920, 0, 200, true)
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	e.mc.probe = probeOf(1080, 1920, 0, 60, true)
	again := func(r *kgo.Record) {
		t.Helper()
		probes, creates := e.mc.calls()
		if err := e.handle(t, r); err != nil {
			t.Fatal(err)
		}
		if p, c := e.mc.calls(); p != probes || c != creates {
			t.Errorf("Probe %d and CreateJob %d more times", p-probes, c-creates)
		}
	}
	again(r)
	sameResult(t, e.events(t), failure(id, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_DURATION_EXCEEDED, recordedDetail))

	// A job running, then complete without a master: the replay finishes it.
	r2, id2, version2 := uploadedRecord(t)
	if err := e.handle(t, r2); err != nil {
		t.Fatal(err)
	}
	again(r2)
	job := e.recordedJob(t, id2, version2)
	e.mc.complete(t, job)
	again(r2)
	want := completedFor(id2, version2, e.attemptOf(t, job))
	// The master exists now.
	again(r2)
	var got []*mediav1.TranscodeEvent
	for _, ev := range e.events(t) {
		if ev.GetTranscodeFailed().GetVideoId() != id {
			got = append(got, ev)
		}
	}
	if len(got) != 2 {
		t.Errorf("%d results for the second video, want 2", len(got))
	}
	sameResult(t, got, want)
}

// A source Probe refuses is recorded with its reason and fails at once, without a job.
func TestProbeRefusals(t *testing.T) {
	t.Parallel()
	edit := func(f func(c *types.Container)) *probeAnswer {
		out := probeOf(1080, 1920, 0, 60, true)
		f(out.ProbeResults[0].Container)
		return &probeAnswer{out: out}
	}
	invalid := mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT
	for name, tt := range map[string]struct {
		answer *probeAnswer
		want   mediav1.TranscodeFailureReason
	}{
		"no duration":    {edit(func(c *types.Container) { c.Duration = nil }), invalid},
		"no video track": {edit(func(c *types.Container) { c.Tracks = c.Tracks[1:] }), invalid},
		"4097 px":        {edit(func(c *types.Container) { c.Tracks[0].VideoProperties.Width = aws.Int32(4097) }), invalid},
		"240 fps":        {edit(func(c *types.Container) { c.Tracks[0].VideoProperties.FrameRate.Numerator = aws.Int32(240) }), invalid},
		"200 s": {edit(func(c *types.Container) { c.Duration = aws.Float64(200) }),
			mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_DURATION_EXCEEDED},
		"object missing": {&probeAnswer{err: &types.NotFoundException{Message: aws.String("not found")}},
			mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_SOURCE_MISSING},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			e := newEnv(t)
			e.mc.probe, e.mc.probeErr = tt.answer.out, tt.answer.err
			r, id, version := uploadedRecord(t)
			if err := e.handle(t, r); err != nil {
				t.Fatal(err)
			}
			if _, creates := e.mc.calls(); creates != 0 {
				t.Errorf("%d jobs created", creates)
			}
			if got, want := string(e.recordOf(id, version)), `{"reason":"`+tt.want.String()+`"}`; got != want {
				t.Errorf("record = %s, want %s", got, want)
			}
			sameResult(t, e.events(t), failure(id, tt.want, recordedDetail))
		})
	}
}

type probeAnswer struct {
	out *mediaconvert.ProbeOutput
	err error
}

// A failure midway publishes nothing half done: a copy failing leaves no master and the next
// delivery copies everything again; a stop right after the master is created publishes nothing and
// the next delivery publishes the same event (a failing publish: TestTranscodeDuration); a stop
// midway leaves the message and the record to come back.
func TestFailuresMidway(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	r, id, version := uploadedRecord(t)
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	job := e.recordedJob(t, id, version)
	e.mc.complete(t, job)
	want := completedFor(id, version, e.attemptOf(t, job))

	e.store.failCopy = 3
	if e.message(t, job, types.JobStatusComplete) {
		t.Error("message done with although a copy failed")
	}
	noMaster(t, e, id, version)

	// The stop comes right after the master is created: nothing is read back or published.
	ctx, cancel := context.WithCancel(t.Context())
	e.store.afterCreate = func(key string) {
		if strings.HasSuffix(key, "/master.m3u8") {
			cancel()
		}
	}
	if err := e.b.Handle(ctx, r, kafkax.Attempt{Number: 2, Last: true}); err == nil {
		t.Error("Handle succeeded although the publish could not")
	}
	e.store.afterCreate = nil
	if n := len(e.events(t)); n != 0 {
		t.Fatalf("%d events published", n)
	}
	for _, k := range e.store.keys("media/" + id + "/") {
		if e.store.caches[k] != immutable {
			t.Errorf("%s has no Cache-Control after the second try", k)
		}
	}
	if !e.message(t, job, types.JobStatusComplete) {
		t.Error("message not done with")
	}
	sameResult(t, e.events(t), want)

	// A stop while copying: nothing published, the message stays.
	r2, id2, version2 := uploadedRecord(t)
	if err := e.handle(t, r2); err != nil {
		t.Fatal(err)
	}
	job2 := e.recordedJob(t, id2, version2)
	e.mc.complete(t, job2)
	ctx2, cancel2 := context.WithCancel(t.Context())
	e.store.beforeCopy = cancel2
	body := stateChangeOf(job2, types.JobStatusComplete)
	if e.b.HandleMessage(ctx2, &body) {
		t.Error("message done with although the bridge stopped")
	}
	e.store.beforeCopy = nil
	if len(e.events(t)) != 1 {
		t.Error("published after the stop")
	}
}

// A message the bridge cannot vouch for is left on the queue, acted on in no way, and logged
// without its content.
func TestMessagesNotActedOn(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	r, id, version := uploadedRecord(t)
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	job := e.recordedJob(t, id, version)
	e.mc.complete(t, job)
	before := len(e.store.keys(""))

	junk := strings.Repeat("A", 4096)
	edits := map[string]func(j *types.Job){
		"other queue":        func(j *types.Job) { j.Queue = aws.String(testQueueARN + "-other") },
		"metadata missing":   func(j *types.Job) { delete(j.UserMetadata, metaAttempt) },
		"version not a UUID": func(j *types.Job) { j.UserMetadata[metaVersion] = junk },
		"destination outside": func(j *types.Job) {
			j.Settings.OutputGroups[0].OutputGroupSettings.HlsGroupSettings.Destination = aws.String("s3://" + testMedia + "/media/" + junk)
		},
	}
	for name, f := range edits {
		saved := *e.mc.job(t, job)
		meta := map[string]string{}
		for k, v := range saved.UserMetadata {
			meta[k] = v
		}
		settings := cloneSettings(saved.Settings)
		e.mc.mu.Lock()
		c := saved
		c.UserMetadata, c.Settings = meta, settings
		f(&c)
		e.mc.jobs[job] = &c
		e.mc.mu.Unlock()
		if e.message(t, job, types.JobStatusComplete) {
			t.Errorf("%s: message done with", name)
		}
		e.mc.mu.Lock()
		e.mc.jobs[job] = &saved
		e.mc.mu.Unlock()
	}
	for name, body := range map[string]string{
		"not JSON":    junk,
		"no job":      stateChangeOf("1700000000999-nojob1", types.JobStatusComplete),
		"bad job ID":  strings.ReplaceAll(stateChangeOf(job, types.JobStatusComplete), job, junk),
		"not a state": `{"source":"aws.mediaconvert","detail-type":"MediaConvert Job State Change","detail":{}}`,
	} {
		if e.b.HandleMessage(t.Context(), &body) {
			t.Errorf("%s: message done with", name)
		}
	}
	if n := len(e.events(t)); n != 0 {
		t.Errorf("%d events published", n)
	}
	if after := len(e.store.keys("")); after != before {
		t.Errorf("objects %d, want %d: a message not vouched for wrote", after, before)
	}
	for _, line := range e.logs.all() {
		if strings.Contains(line, strings.Repeat("A", 600)) {
			t.Errorf("log line carries the message content: %.200s…", line)
		}
	}
}

// cloneSettings copies the parts of settings the tests edit.
func cloneSettings(s *types.JobSettings) *types.JobSettings {
	c := *s
	c.OutputGroups = slices.Clone(s.OutputGroups)
	for i, g := range c.OutputGroups {
		ogs := *g.OutputGroupSettings
		if ogs.HlsGroupSettings != nil {
			h := *ogs.HlsGroupSettings
			ogs.HlsGroupSettings = &h
		}
		c.OutputGroups[i].OutputGroupSettings = &ogs
	}
	return &c
}

// Cleanup between: job B fails and is published; video-service deletes media/<video_id>/; job A,
// not in the record, then completes, and video.uploaded is replayed, before and after a restart.
// The record outlives the cleanup, so nothing completes the version and the reason stays.
func TestCleanupDoesNotReopenAFailedVersion(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	r, id, version := uploadedRecord(t)
	e.mc.lose = 1
	_ = e.handle(t, r) // job A: created, answer lost, never recorded
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	jobs := e.mc.jobIDs()
	jobA, jobB := jobs[0], jobs[1]
	e.mc.fail(t, jobB, 1076)
	e.message(t, jobB, types.JobStatusError)
	want := jobFailed(id, jobB, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT, 1076)
	record := string(e.recordOf(id, version))

	e.store.deletePrefix("media/" + id + "/")
	e.mc.complete(t, jobA)
	e.message(t, jobA, types.JobStatusComplete)
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	e.b = e.bridge()
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	e.message(t, jobA, types.JobStatusComplete)

	evs := e.events(t)
	sameResult(t, evs, want)
	if len(evs) != 5 {
		t.Errorf("%d events, want B's failure and four replays of it", len(evs))
	}
	noMaster(t, e, id, version)
	if got := string(e.recordOf(id, version)); got != record {
		t.Errorf("record = %s, want %s", got, record)
	}
}

// The loop deletes a message once it is settled, leaves one it cannot act on, and returns when
// stopped.
func TestRunEventsDeletesSettledMessages(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	r, id, version := uploadedRecord(t)
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	job := e.recordedJob(t, id, version)
	e.mc.complete(t, job)
	e.queue.send("not an event")
	e.queue.send(stateChangeOf(job, types.JobStatusComplete))

	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() { done <- e.b.RunEvents(ctx) }()
	deadline := time.Now().Add(10 * time.Second)
	for e.queue.left() != 1 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	if err := <-done; err != nil {
		t.Errorf("RunEvents() = %v", err)
	}
	if e.queue.left() != 1 || !slices.Equal(e.queue.deleted, []string{"receipt-1"}) {
		t.Errorf("deleted %v, left %d; want only the state change deleted", e.queue.deleted, e.queue.left())
	}
	sameResult(t, e.events(t), completedFor(id, version, e.attemptOf(t, job)))
}

// The job carries the trace of the video.uploaded, and the message's work joins it.
func TestTraceFollowsTheJob(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	r, _, _ := uploadedRecord(t)
	ctx := propagation.TraceContext{}.Extract(t.Context(), propagation.MapCarrier{"traceparent": sampleTraceparent})
	if err := e.b.Handle(ctx, r, kafkax.Attempt{Number: 1}); err != nil {
		t.Fatal(err)
	}
	job := e.mc.job(t, e.mc.jobIDs()[0])
	if got := job.UserMetadata[metaTraceparent]; !strings.HasPrefix(got, "00-0af7651916cd43dd8448eb211c80319c-") {
		t.Errorf("job traceparent %q is not in the record's trace", got)
	}
}

// svp.transcode.duration: one ready sample per version, from the recorded job's timing, however
// often COMPLETE comes, even when the read back or publish fails after the master is created; one
// failed sample per delivery of the recorded job's own ERROR message; nothing for a recorded
// reason, a replay or a stray job. Not parallel: it swaps the global meter provider.
func TestTranscodeDuration(t *testing.T) {
	reader := sdkmetric.NewManualReader()
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))
	prev := otel.GetMeterProvider()
	otel.SetMeterProvider(mp)
	t.Cleanup(func() {
		otel.SetMeterProvider(prev)
		_ = mp.Shutdown(context.Background())
	})
	e := newEnv(t)

	r, id, version := uploadedRecord(t)
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	job := e.recordedJob(t, id, version)
	e.mc.complete(t, job)
	e.message(t, job, types.JobStatusComplete)
	e.message(t, job, types.JobStatusComplete)
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}

	r2, _, _ := uploadedRecord(t)
	e.mc.lose = 1
	_ = e.handle(t, r2)
	if err := e.handle(t, r2); err != nil {
		t.Fatal(err)
	}
	jobs := e.mc.jobIDs()
	stray, recorded := jobs[1], jobs[2]
	e.mc.fail(t, stray, 1010)
	e.mc.fail(t, recorded, 1010)
	e.message(t, stray, types.JobStatusError)
	e.message(t, recorded, types.JobStatusError)
	e.message(t, recorded, types.JobStatusError)
	if err := e.handle(t, r2); err != nil {
		t.Fatal(err)
	}

	r3, _, _ := uploadedRecord(t)
	e.mc.probe = probeOf(1080, 1920, 0, 200, true)
	if err := e.handle(t, r3); err != nil {
		t.Fatal(err)
	}

	// The first delivery creates the master, then a read back or the publish fails; the next one
	// publishes from the master.
	e.mc.probe = probeOf(1080, 1920, 0, 60, true)
	for _, failPublish := range []bool{false, true} {
		r, id, version := uploadedRecord(t)
		if err := e.handle(t, r); err != nil {
			t.Fatal(err)
		}
		job := e.recordedJob(t, id, version)
		e.mc.complete(t, job)
		before := len(e.events(t))
		ctx, cancel := context.WithCancel(t.Context())
		producer := e.b.producer
		if failPublish {
			closed, err := kafkax.NewClient(e.brokers, "closed")
			if err != nil {
				t.Fatal(err)
			}
			closed.Close()
			e.b.producer = closed
		} else {
			e.store.afterCreate = func(key string) {
				if strings.HasSuffix(key, "/master.m3u8") {
					cancel()
				}
			}
		}
		body := stateChangeOf(job, types.JobStatusComplete)
		done := e.b.HandleMessage(ctx, &body)
		cancel()
		e.store.afterCreate, e.b.producer = nil, producer
		if done || e.store.get("media/"+id+"/"+version+"/master.m3u8") == nil || len(e.events(t)) != before {
			t.Fatalf("publish failing %v: message done with %v, or no master, or an event published", failPublish, done)
		}
		if !e.message(t, job, types.JobStatusComplete) {
			t.Fatalf("publish failing %v: message not done with on the next delivery", failPublish)
		}
		sameResult(t, e.events(t)[before:], completedFor(id, version, e.attemptOf(t, job)))
	}

	var data metricdata.ResourceMetrics
	if err := reader.Collect(t.Context(), &data); err != nil {
		t.Fatal(err)
	}
	points := map[string]metricdata.HistogramDataPoint[float64]{}
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			if m.Name != "svp.transcode.duration" {
				continue
			}
			for _, p := range m.Data.(metricdata.Histogram[float64]).DataPoints {
				outcome, _ := p.Attributes.Value(attribute.Key("outcome"))
				points[outcome.AsString()] = p
			}
		}
	}
	if len(points) != 2 || points["ready"].Count != 3 || points["ready"].Sum != 36 ||
		points["failed"].Count != 2 || points["failed"].Sum != 6 {
		t.Errorf("samples = %+v, want three ready of 12 s and two failed of 3 s", points)
	}
}
