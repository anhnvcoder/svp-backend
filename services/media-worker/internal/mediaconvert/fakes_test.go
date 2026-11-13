package mediaconvert

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/mediaconvert"
	"github.com/aws/aws-sdk-go-v2/service/mediaconvert/types"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	sqstypes "github.com/aws/aws-sdk-go-v2/service/sqs/types"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	eventv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/event/v1"
	mediav1 "github.com/anhnvcoder/svp-backend/gen/go/svp/media/v1"
	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/worker"
)

// Resources of the tests, in the shapes of the cluster contract.
const (
	testQueueARN  = "arn:aws:mediaconvert:ap-southeast-1:000000000000:queues/svp-stg"
	testRoleARN   = "arn:aws:iam::000000000000:role/svp-stg-mediaconvert"
	testEventsURL = "https://sqs.ap-southeast-1.amazonaws.com/000000000000/svp-stg-transcode-events"
	testUploads   = "svp-stg-uploads-000000000000-ap-southeast-1"
	testMedia     = "svp-stg-media-000000000000-ap-southeast-1"
)

// fakeStore keeps objects in memory and follows objstore's error contract, Create's
// If-None-Match: * included.
type fakeStore struct {
	mu      sync.Mutex
	objects map[string][]byte
	types   map[string]string
	caches  map[string]string
	// copies counts Copy calls; failCopy, when set, fails the copy with that number (from 1).
	copies   int
	failCopy int
	// failCreate, when set, fails Create of keys it returns true for, without writing.
	failCreate func(key string) bool
	// afterCreate, when set, runs after a successful Create.
	afterCreate func(key string)
	// beforeCopy, when set, runs before each Copy.
	beforeCopy func()
}

func newFakeStore() *fakeStore {
	return &fakeStore{objects: map[string][]byte{}, types: map[string]string{}, caches: map[string]string{}}
}

func (s *fakeStore) put(key string, data []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.objects[key] = data
	delete(s.types, key)
	delete(s.caches, key)
}

func (s *fakeStore) get(key string) []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.objects[key]
}

// keys lists the keys under prefix, sorted.
func (s *fakeStore) keys(prefix string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for k := range s.objects {
		if strings.HasPrefix(k, prefix) {
			out = append(out, k)
		}
	}
	slices.Sort(out)
	return out
}

// deletePrefix is the cleanup of video-service: DeletePrefix media/<video_id>/.
func (s *fakeStore) deletePrefix(prefix string) {
	for _, k := range s.keys(prefix) {
		s.mu.Lock()
		delete(s.objects, k)
		s.mu.Unlock()
	}
}

func (s *fakeStore) Download(ctx context.Context, key, path string, maxBytes int64) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	data := s.get(key)
	if data == nil {
		return fmt.Errorf("download %s: %w", key, objstore.ErrNotFound)
	}
	if int64(len(data)) > maxBytes {
		return fmt.Errorf("download %s: %w", key, objstore.ErrTooLarge)
	}
	return os.WriteFile(path, data, 0o600)
}

func (s *fakeStore) Create(ctx context.Context, key, path, contentType, cacheControl string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if s.failCreate != nil && s.failCreate(key) {
		return errors.New("objstore: upload " + key + ": 503 Service Unavailable")
	}
	data, err := os.ReadFile(path) //nolint:gosec // a file of the try under test
	if err != nil {
		return err
	}
	s.mu.Lock()
	if _, taken := s.objects[key]; taken {
		s.mu.Unlock()
		return fmt.Errorf("upload %s: %w", key, objstore.ErrExists)
	}
	s.objects[key], s.types[key], s.caches[key] = data, contentType, cacheControl
	hook := s.afterCreate
	s.mu.Unlock()
	if hook != nil {
		hook(key)
	}
	return nil
}

func (s *fakeStore) Exists(ctx context.Context, key string) (bool, error) {
	return s.get(key) != nil, ctx.Err()
}

func (s *fakeStore) List(ctx context.Context, prefix string) ([]string, error) {
	return s.keys(prefix), ctx.Err()
}

func (s *fakeStore) Copy(ctx context.Context, src, dst, contentType, cacheControl string) error {
	if s.beforeCopy != nil {
		s.beforeCopy()
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.copies++
	if s.copies == s.failCopy {
		return errors.New("objstore: copy " + src + ": 503 Service Unavailable")
	}
	data, ok := s.objects[src]
	if !ok {
		return fmt.Errorf("copy %s: %w", src, objstore.ErrNotFound)
	}
	s.objects[dst], s.types[dst], s.caches[dst] = data, contentType, cacheControl
	return nil
}

// fakeMC is MediaConvert in memory: jobs stay SUBMITTED until a test completes or fails them.
type fakeMC struct {
	mu    sync.Mutex
	store *fakeStore
	jobs  map[string]*types.Job
	// probe answers every Probe; probeErr, when set, is returned instead.
	probe    *mediaconvert.ProbeOutput
	probeErr error
	// probes and creates count the calls.
	probes, creates int
	// lose makes the next n CreateJob calls create their job and return an error, as when the
	// response is lost.
	lose int
	// beforeCreate, when set, runs at the start of each CreateJob.
	beforeCreate func()
}

func newFakeMC(store *fakeStore) *fakeMC {
	return &fakeMC{store: store, jobs: map[string]*types.Job{}, probe: probeOf(1080, 1920, 0, 60, true)}
}

func (m *fakeMC) Probe(context.Context, *mediaconvert.ProbeInput, ...func(*mediaconvert.Options)) (*mediaconvert.ProbeOutput, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.probes++
	if m.probeErr != nil {
		return nil, m.probeErr
	}
	return m.probe, nil
}

func (m *fakeMC) CreateJob(_ context.Context, in *mediaconvert.CreateJobInput, _ ...func(*mediaconvert.Options)) (*mediaconvert.CreateJobOutput, error) {
	m.mu.Lock()
	hook := m.beforeCreate
	m.mu.Unlock()
	if hook != nil {
		hook()
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.creates++
	id := fmt.Sprintf("1700000000%03d-job%03d", len(m.jobs), len(m.jobs))
	m.jobs[id] = &types.Job{
		Id: aws.String(id), Queue: in.Queue, Role: in.Role, Settings: in.Settings, UserMetadata: in.UserMetadata,
		Status: types.JobStatusSubmitted,
	}
	if m.lose > 0 {
		m.lose--
		return nil, errors.New("operation error MediaConvert: CreateJob, https response error: read: connection reset by peer")
	}
	return &mediaconvert.CreateJobOutput{Job: m.jobs[id]}, nil
}

func (m *fakeMC) GetJob(_ context.Context, in *mediaconvert.GetJobInput, _ ...func(*mediaconvert.Options)) (*mediaconvert.GetJobOutput, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	job, ok := m.jobs[aws.ToString(in.Id)]
	if !ok {
		return nil, &types.NotFoundException{Message: aws.String("job not found")}
	}
	c := *job
	return &mediaconvert.GetJobOutput{Job: &c}, nil
}

// job returns job id as stored.
func (m *fakeMC) job(t *testing.T, id string) *types.Job {
	t.Helper()
	m.mu.Lock()
	defer m.mu.Unlock()
	job, ok := m.jobs[id]
	if !ok {
		t.Fatalf("no job %s", id)
	}
	return job
}

// jobIDs lists the jobs created, in order.
func (m *fakeMC) jobIDs() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]string, 0, len(m.jobs))
	for id := range m.jobs {
		out = append(out, id)
	}
	slices.Sort(out)
	return out
}

func (m *fakeMC) calls() (probes, creates int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.probes, m.creates
}

// segmentLengths are the #EXTINF values of every rendition playlist the fake writes: 6.02 s in
// all, while the job reports 6000 ms, so a result read from the event would differ.
var segmentLengths = []string{"4.000000", "2.020000"}

// complete ends job id as MediaConvert does: its outputs written under its destinations, without
// Cache-Control, and the sizes of its HLS outputs reported in reverse order.
func (m *fakeMC) complete(t *testing.T, id string) {
	t.Helper()
	job := m.job(t, id)
	m.mu.Lock()
	defer m.mu.Unlock()
	var details []types.OutputGroupDetail
	for _, g := range job.Settings.OutputGroups {
		var out []types.OutputDetail
		for _, o := range g.Outputs {
			vd := o.VideoDescription
			out = append(out, types.OutputDetail{DurationInMs: aws.Int32(6000),
				VideoDetails: &types.VideoDetail{WidthInPx: vd.Width, HeightInPx: vd.Height}})
		}
		slices.Reverse(out)
		details = append(details, types.OutputGroupDetail{OutputDetails: out})
		if s := g.OutputGroupSettings.HlsGroupSettings; s != nil {
			base := strings.TrimPrefix(aws.ToString(s.Destination), "s3://"+testMedia+"/")
			m.store.put(base+".m3u8", []byte("#EXTM3U\n"))
			for _, o := range g.Outputs {
				name := base + aws.ToString(o.NameModifier)
				playlist := "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n"
				for i, l := range segmentLengths {
					seg := fmt.Sprintf("%s_%05d.ts", name, i+1)
					m.store.put(seg, []byte("segment"))
					playlist += "#EXTINF:" + l + ",\n" + seg[strings.LastIndex(seg, "/")+1:] + "\n"
				}
				m.store.put(name+".m3u8", []byte(playlist+"#EXT-X-ENDLIST\n"))
			}
		}
		if s := g.OutputGroupSettings.FileGroupSettings; s != nil {
			m.store.put(strings.TrimPrefix(aws.ToString(s.Destination), "s3://"+testMedia+"/")+".0000000.jpg", []byte("jpeg"))
		}
	}
	start := time.Date(2026, 11, 13, 8, 0, 0, 0, time.UTC)
	job.Status = types.JobStatusComplete
	job.OutputGroupDetails = details
	job.Timing = &types.Timing{StartTime: aws.Time(start), FinishTime: aws.Time(start.Add(12 * time.Second))}
}

// fail ends job id in ERROR with code.
func (m *fakeMC) fail(t *testing.T, id string, code int32) {
	t.Helper()
	job := m.job(t, id)
	m.mu.Lock()
	defer m.mu.Unlock()
	start := time.Date(2026, 11, 13, 8, 0, 0, 0, time.UTC)
	job.Status, job.ErrorCode, job.ErrorMessage = types.JobStatusError, aws.Int32(code), aws.String("error of the fake")
	job.Timing = &types.Timing{StartTime: aws.Time(start), FinishTime: aws.Time(start.Add(3 * time.Second))}
}

// probeOf is a Probe answer for a source of width x height encoded with rotation, length
// seconds at 30 fps, with an audio track when audio is set.
func probeOf(width, height, rotation int32, seconds float64, audio bool) *mediaconvert.ProbeOutput {
	tracks := []types.Track{{TrackType: types.TrackTypeVideo, Duration: aws.Float64(seconds), VideoProperties: &types.VideoProperties{
		Width: aws.Int32(width), Height: aws.Int32(height),
		FrameRate: &types.FrameRate{Numerator: aws.Int32(30), Denominator: aws.Int32(1)},
	}}}
	if rotation != 0 {
		tracks[0].VideoProperties.Rotation = aws.Int32(rotation)
	}
	if audio {
		tracks = append(tracks, types.Track{TrackType: types.TrackTypeAudio, Duration: aws.Float64(seconds)})
	}
	return &mediaconvert.ProbeOutput{ProbeResults: []types.ProbeResult{{
		Container: &types.Container{Duration: aws.Float64(seconds), Tracks: tracks},
	}}}
}

// fakeQueue is an SQS queue in memory: every receive returns the messages not deleted yet.
type fakeQueue struct {
	mu       sync.Mutex
	messages map[string]string // receipt handle -> body
	order    []string
	deleted  []string
	receives int
}

func (q *fakeQueue) send(body string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.messages == nil {
		q.messages = map[string]string{}
	}
	h := fmt.Sprintf("receipt-%d", len(q.order))
	q.messages[h] = body
	q.order = append(q.order, h)
}

func (q *fakeQueue) ReceiveMessage(ctx context.Context, in *sqs.ReceiveMessageInput, _ ...func(*sqs.Options)) (*sqs.ReceiveMessageOutput, error) {
	q.mu.Lock()
	q.receives++
	var out []sqstypes.Message
	for _, h := range q.order {
		if body, ok := q.messages[h]; ok && len(out) < int(in.MaxNumberOfMessages) {
			out = append(out, sqstypes.Message{ReceiptHandle: aws.String(h), Body: aws.String(body)})
		}
	}
	q.mu.Unlock()
	if len(out) == 0 {
		// Long polling: wait a little, or until the loop stops.
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
	}
	return &sqs.ReceiveMessageOutput{Messages: out}, nil
}

func (q *fakeQueue) DeleteMessage(_ context.Context, in *sqs.DeleteMessageInput, _ ...func(*sqs.Options)) (*sqs.DeleteMessageOutput, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	h := aws.ToString(in.ReceiptHandle)
	delete(q.messages, h)
	q.deleted = append(q.deleted, h)
	return &sqs.DeleteMessageOutput{}, nil
}

func (q *fakeQueue) left() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.messages)
}

// stateChange is the body EventBridge sends for job id reaching status.
func stateChangeOf(id string, status types.JobStatus) string {
	return fmt.Sprintf(`{"version":"0","id":"e1","detail-type":"MediaConvert Job State Change","source":"aws.mediaconvert",`+
		`"account":"000000000000","region":"ap-southeast-1","resources":["arn:aws:mediaconvert:ap-southeast-1:000000000000:jobs/%[1]s"],`+
		`"detail":{"queue":"%[2]s","jobId":"%[1]s","status":"%[3]s","userMetadata":{}}}`, id, testQueueARN, status)
}

// env is a bridge wired to an in-memory Kafka, MediaConvert, SQS queue and store.
type env struct {
	brokers string
	client  *kgo.Client
	store   *fakeStore
	mc      *fakeMC
	queue   *fakeQueue
	workDir string
	b       *Bridge
	logs    *logRecorder
}

func newEnv(t *testing.T) *env {
	t.Helper()
	c, err := kfake.NewCluster(kfake.NumBrokers(1),
		kfake.SeedTopics(1, worker.InputTopic, worker.InputTopic+kafkax.DLQSuffix, worker.OutputTopic))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	brokers := strings.Join(c.ListenAddrs(), ",")
	cl, err := kafkax.NewClient(brokers, "test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cl.Close)
	store := newFakeStore()
	e := &env{brokers: brokers, client: cl, store: store, mc: newFakeMC(store), queue: &fakeQueue{}, workDir: t.TempDir(),
		logs: &logRecorder{}}
	e.b = e.bridge()
	return e
}

// bridge returns a new bridge on the same resources, as after a restart.
func (e *env) bridge() *Bridge {
	b := New(Config{
		QueueARN: testQueueARN, RoleARN: testRoleARN, EventsQueueURL: testEventsURL,
		UploadsBucket: testUploads, MediaBucket: testMedia, WorkDir: e.workDir,
	}, e.mc, e.queue, e.store, e.client, slog.New(e.logs))
	b.receiveRetry = time.Millisecond
	return b
}

// logRecorder keeps every log record as one line of its message and attributes.
type logRecorder struct {
	mu    sync.Mutex
	lines []string
}

func (*logRecorder) Enabled(context.Context, slog.Level) bool { return true }

func (l *logRecorder) Handle(_ context.Context, r slog.Record) error {
	line := r.Message
	r.Attrs(func(a slog.Attr) bool {
		line += " " + a.String()
		return true
	})
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lines = append(l.lines, line)
	return nil
}

func (l *logRecorder) WithAttrs([]slog.Attr) slog.Handler { return l }
func (l *logRecorder) WithGroup(string) slog.Handler      { return l }

func (l *logRecorder) all() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return slices.Clone(l.lines)
}

// uploadedRecord returns a valid video.uploaded of a new video and its version.
func uploadedRecord(t *testing.T) (r *kgo.Record, id, version string) {
	t.Helper()
	id, version = ids.New(), ids.New()
	ev := &videov1.VideoEvent{
		Meta: &eventv1.EventMeta{EventId: version, OccurredAt: timestamppb.Now()},
		Event: &videov1.VideoEvent_VideoUploaded{VideoUploaded: &videov1.VideoUploaded{
			VideoId: id, AuthorId: ids.New(), SourceKey: objstore.UploadsPrefix + id, ContentType: "video/mp4", SizeBytes: 1 << 20,
		}},
	}
	value, err := proto.Marshal(ev)
	if err != nil {
		t.Fatal(err)
	}
	return &kgo.Record{Topic: worker.InputTopic, Key: []byte(id), Value: value}, id, version
}

// handle runs one try at r, not the last.
func (e *env) handle(t *testing.T, r *kgo.Record) error {
	t.Helper()
	return e.b.Handle(t.Context(), r, kafkax.Attempt{Number: 1})
}

// message hands the state change of job id to the bridge and reports whether it is done with.
func (e *env) message(t *testing.T, id string, status types.JobStatus) bool {
	t.Helper()
	body := stateChangeOf(id, status)
	return e.b.HandleMessage(t.Context(), &body)
}

// events returns every event published so far, without their envelopes.
func (e *env) events(t *testing.T) []*mediav1.TranscodeEvent {
	t.Helper()
	marker := &kgo.Record{Topic: worker.OutputTopic, Key: []byte("marker")}
	if err := kafkax.Produce(t.Context(), e.client, marker); err != nil {
		t.Fatal(err)
	}
	n := int(marker.Offset)
	cl, err := kafkax.NewClient(e.brokers, "test-reader", kgo.ConsumeTopics(worker.OutputTopic), kgo.FetchMaxWait(100*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	var records []*kgo.Record
	for len(records) < n+1 && ctx.Err() == nil {
		records = append(records, cl.PollFetches(ctx).Records()...)
	}
	if len(records) < n+1 {
		t.Fatalf("read %d records, want %d", len(records), n+1)
	}
	out := make([]*mediav1.TranscodeEvent, 0, n)
	for _, r := range records[:n] {
		if string(r.Key) == "marker" {
			continue // of an earlier call
		}
		var ev mediav1.TranscodeEvent
		if err := proto.Unmarshal(r.Value, &ev); err != nil {
			t.Fatal(err)
		}
		if _, err := ids.Parse(ev.GetMeta().GetEventId()); err != nil {
			t.Errorf("meta.event_id %q: %v", ev.GetMeta().GetEventId(), err)
		}
		vid := ev.GetTranscodeCompleted().GetVideoId() + ev.GetTranscodeFailed().GetVideoId()
		if string(r.Key) != vid {
			t.Errorf("record key %q, video_id %q", r.Key, vid)
		}
		ev.Meta = nil
		out = append(out, &ev)
	}
	return out
}

// sameResult checks evs holds at least one event and that they all carry want.
func sameResult(t *testing.T, evs []*mediav1.TranscodeEvent, want *mediav1.TranscodeEvent) {
	t.Helper()
	if len(evs) == 0 {
		t.Fatal("no event published")
	}
	for i, ev := range evs {
		if !proto.Equal(ev, want) {
			t.Errorf("event %d = %v, want %v", i, ev, want)
		}
	}
}

// recordOf returns the job record of the version, nil when there is none.
func (e *env) recordOf(id, version string) []byte {
	return e.store.get(recordKey(id, version))
}

// recordedJob returns the job of the record of the version.
func (e *env) recordedJob(t *testing.T, id, version string) string {
	t.Helper()
	data := e.recordOf(id, version)
	var r record
	if data == nil || json.Unmarshal(data, &r) != nil || r.JobID == "" {
		t.Fatalf("record of %s/%s = %s, want a job", id, version, data)
	}
	return r.JobID
}
