// Package sandboxtest runs the MediaConvert bridge on the output of a real job, recorded in a
// sandbox account with the account, buckets and IDs replaced: the answers of Probe for three
// sources, the GetJob of a completed job, the keys that job wrote and its rendition playlists.
// Only storage and Kafka are stand-ins; what MediaConvert answered and wrote is the recording.
package sandboxtest

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/mediaconvert"
	"github.com/aws/aws-sdk-go-v2/service/mediaconvert/types"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/durationpb"

	mediav1 "github.com/anhnvcoder/svp-backend/gen/go/svp/media/v1"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	bridge "github.com/anhnvcoder/svp-backend/services/media-worker/internal/mediaconvert"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/transcode"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/worker"
)

// Resources of the sandbox as they appear in the recording.
const (
	queueARN  = "arn:aws:mediaconvert:ap-southeast-1:000000000000:queues/svp-stg"
	roleARN   = "arn:aws:iam::000000000000:role/svp-stg-mediaconvert"
	eventsURL = "https://sqs.ap-southeast-1.amazonaws.com/000000000000/svp-stg-transcode-events"
	uploads   = "svp-stg-uploads-000000000000-ap-southeast-1"
	media     = "svp-stg-media-000000000000-ap-southeast-1"
)

// probe decodes testdata/name, the answer of Probe, refusing any field the SDK does not know: a
// field the bridge reads under another name would otherwise be dropped silently.
func probe(t *testing.T, name string) *mediaconvert.ProbeOutput {
	t.Helper()
	var out mediaconvert.ProbeOutput
	decodeStrict(t, name, &out)
	return &out
}

func decodeStrict(t *testing.T, name string, v any) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name)) //nolint:gosec // a fixture named by the test
	if err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
}

// TestInspect checks the input check on what Probe really answers: duration, sound and the size
// as displayed, after the rotation of the container.
func TestInspect(t *testing.T) {
	cases := []struct {
		file   string
		want   bridge.Source
		reason mediav1.TranscodeFailureReason
	}{
		{file: "probe-60s.json", want: bridge.Source{Width: 1080, Height: 1920, FPS: 30, Duration: 60 * time.Second, Audio: true}},
		// Frames of 1920x1080 shown turned by 90 degrees: Probe reports Rotation 270.
		{file: "probe-rot90.json", want: bridge.Source{Width: 1080, Height: 1920, FPS: 30, Duration: 10 * time.Second}},
		{file: "probe-200s.json", reason: mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_DURATION_EXCEEDED},
	}
	for _, c := range cases {
		t.Run(c.file, func(t *testing.T) {
			src, reason, detail := bridge.Inspect(probe(t, c.file).ProbeResults)
			if reason != c.reason || src != c.want {
				t.Errorf("Inspect = %+v, %v (%s), want %+v, %v", src, reason, detail, c.want, c.reason)
			}
		})
	}
}

// TestCompletedJob hands the state change of the recorded job to the bridge, with storage holding
// the keys that job wrote, and checks the layout of its output, the master the bridge creates and
// the transcode.completed it publishes. Not parallel: it swaps the global meter provider.
func TestCompletedJob(t *testing.T) {
	reader := sdkmetric.NewManualReader()
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))
	prev := otel.GetMeterProvider()
	otel.SetMeterProvider(mp)
	t.Cleanup(func() {
		otel.SetMeterProvider(prev)
		_ = mp.Shutdown(context.Background())
	})

	var out mediaconvert.GetJobOutput
	decodeStrict(t, "get-job.json", &out)
	job := out.Job
	videoID, version, attempt := job.UserMetadata["video_id"], job.UserMetadata["version"], job.UserMetadata["attempt"]
	prefix := objstore.MediaPrefix + videoID + "/" + version + "/"
	dir := prefix + attempt + "/"

	if job.Timing == nil || job.Timing.StartTime == nil || job.Timing.FinishTime == nil {
		t.Fatalf("Timing = %+v, want StartTime and FinishTime", job.Timing)
	}
	renditions, err := bridge.JobRenditions(job)
	if err != nil {
		t.Fatal(err)
	}
	if got := names(renditions); !slices.Equal(got, []string{"360p", "720p", "1080p"}) {
		t.Errorf("renditions = %v, want 360p, 720p, 1080p", got)
	}

	store := newStore(t)
	keys := store.keys(objstore.MediaPrefix)
	for _, k := range keys {
		if name, ok := strings.CutPrefix(k, dir); !ok || name == "" || strings.Contains(name, "/") {
			t.Errorf("key %s is not flat in the attempt directory %s", k, dir)
		}
	}
	for _, r := range renditions {
		playlist := dir + "index_" + r.Name + ".m3u8"
		if !slices.Contains(keys, playlist) {
			t.Errorf("no playlist %s for rendition %s", playlist, r.Name)
			continue
		}
		for _, seg := range segments(store.get(playlist)) {
			if !slices.Contains(keys, dir+seg) {
				t.Errorf("playlist of %s names %s, not written", r.Name, seg)
			}
		}
	}

	brokers, client := kafka(t)
	b := bridge.New(bridge.Config{
		QueueARN: queueARN, RoleARN: roleARN, EventsQueueURL: eventsURL, UploadsBucket: uploads, MediaBucket: media,
		WorkDir: t.TempDir(),
	}, &recordedMC{job: job}, nil, store, client, slog.New(slog.DiscardHandler))
	body := fmt.Sprintf(`{"detail-type":"MediaConvert Job State Change","source":"aws.mediaconvert",`+
		`"detail":{"queue":%q,"jobId":%q,"status":"COMPLETE"}}`, queueARN, aws.ToString(job.Id))
	if !b.HandleMessage(t.Context(), &body) {
		t.Fatal("HandleMessage did not settle the completed job")
	}

	master := store.get(prefix + transcode.MasterPlaylist)
	m, err := transcode.ParseMaster(master)
	if err != nil {
		t.Fatalf("master %q: %v", master, err)
	}
	if m.Attempt != attempt || !slices.Equal(m.Renditions, renditions) {
		t.Errorf("master = %+v, want attempt %s and %+v", m, attempt, renditions)
	}
	// MediaConvert's own manifest of the group stays in the directory, unused by any master.
	if !slices.Contains(keys, dir+"index.m3u8") || bytes.Contains(master, []byte("/index.m3u8")) {
		t.Errorf("index.m3u8 listed: %t, master %q, want listed and not named", slices.Contains(keys, dir+"index.m3u8"), master)
	}
	for _, k := range store.keys(dir) {
		if c := store.cache(k); c != worker.CacheControl {
			t.Errorf("%s has Cache-Control %q, want %q", k, c, worker.CacheControl)
		}
	}
	if store.get(dir+transcode.Thumbnail) == nil {
		t.Errorf("no %s", transcode.Thumbnail)
	}

	lowest, err := transcode.PlaylistDuration(store.get(prefix + m.LowestPlaylist()))
	if err != nil {
		t.Fatal(err)
	}
	if d := lowest - 60*time.Second; d < -transcode.SegmentSeconds*time.Second || d > transcode.SegmentSeconds*time.Second {
		t.Errorf("PlaylistDuration of the lowest rendition = %v, want 60 s within one segment", lowest)
	}

	want := &mediav1.TranscodeEvent{Event: &mediav1.TranscodeEvent_TranscodeCompleted{TranscodeCompleted: &mediav1.TranscodeCompleted{
		VideoId: videoID, PlaylistKey: prefix + transcode.MasterPlaylist, ThumbnailKey: dir + transcode.Thumbnail,
		Duration: durationpb.New(lowest),
		Renditions: []*mediav1.Rendition{
			{Name: "360p", Width: 360, Height: 640, BitrateBps: jobBitrate(job, 0)},
			{Name: "720p", Width: 720, Height: 1280, BitrateBps: jobBitrate(job, 1)},
			{Name: "1080p", Width: 1080, Height: 1920, BitrateBps: jobBitrate(job, 2)},
		},
	}}}
	got := published(t, brokers)
	got.Meta = nil
	if !proto.Equal(got, want) {
		t.Errorf("published %v, want %v", got, want)
	}

	if sum, ok := readySample(t, reader); !ok || sum != job.Timing.FinishTime.Sub(*job.Timing.StartTime).Seconds() {
		t.Errorf("ready sample of svp.transcode.duration = %v (%t), want FinishTime - StartTime of the job", sum, ok)
	}
}

// jobBitrate is the target bitrate of HLS output i in the settings of the recorded job.
func jobBitrate(job *types.Job, i int) int32 {
	return aws.ToInt32(job.Settings.OutputGroups[0].Outputs[i].VideoDescription.CodecSettings.H264Settings.Bitrate)
}

func names(rs []transcode.Rendition) []string {
	out := make([]string, 0, len(rs))
	for _, r := range rs {
		out = append(out, r.Name)
	}
	return out
}

// segments lists the URIs of a media playlist.
func segments(playlist []byte) []string {
	var out []string
	sc := bufio.NewScanner(bytes.NewReader(playlist))
	for sc.Scan() {
		if line := strings.TrimSpace(sc.Text()); line != "" && !strings.HasPrefix(line, "#") {
			out = append(out, line)
		}
	}
	return out
}

// recordedMC answers GetJob with the recorded job; the bridge calls nothing else on a state change.
type recordedMC struct {
	bridge.Client
	job *types.Job
}

func (m *recordedMC) GetJob(context.Context, *mediaconvert.GetJobInput, ...func(*mediaconvert.Options)) (*mediaconvert.GetJobOutput, error) {
	c := *m.job
	return &mediaconvert.GetJobOutput{Job: &c}, nil
}

// store keeps objects in memory and follows objstore's error contract.
type store struct {
	mu      sync.Mutex
	objects map[string][]byte
	caches  map[string]string
}

// newStore holds every key of testdata/keys.txt, a listing of the job's output: the recorded
// playlists under their names, any other object a few placeholder bytes.
func newStore(t *testing.T) *store {
	t.Helper()
	s := &store{objects: map[string][]byte{}, caches: map[string]string{}}
	data, err := os.ReadFile(filepath.Join("testdata", "keys.txt"))
	if err != nil {
		t.Fatal(err)
	}
	sc := bufio.NewScanner(bytes.NewReader(data))
	for sc.Scan() {
		// date, time, size, key
		f := strings.Fields(sc.Text())
		if len(f) != 4 {
			t.Fatalf("keys.txt: line %q is not date, time, size and key", sc.Text())
		}
		content := []byte("object")
		if p, err := os.ReadFile(filepath.Join("testdata", "playlists", path.Base(f[3]))); err == nil {
			content = p
		}
		s.objects[f[3]] = content
	}
	if len(s.objects) == 0 {
		t.Fatal("keys.txt lists no key")
	}
	return s
}

func (s *store) get(key string) []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.objects[key]
}

func (s *store) cache(key string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.caches[key]
}

func (s *store) keys(prefix string) []string {
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

func (s *store) Download(_ context.Context, key, path string, maxBytes int64) error {
	data := s.get(key)
	switch {
	case data == nil:
		return fmt.Errorf("download %s: %w", key, objstore.ErrNotFound)
	case int64(len(data)) > maxBytes:
		return fmt.Errorf("download %s: %w", key, objstore.ErrTooLarge)
	}
	return os.WriteFile(path, data, 0o600)
}

func (s *store) Create(_ context.Context, key, path, _, cacheControl string) error {
	data, err := os.ReadFile(path) //nolint:gosec // a file of the try under test
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, taken := s.objects[key]; taken {
		return fmt.Errorf("upload %s: %w", key, objstore.ErrExists)
	}
	s.objects[key], s.caches[key] = data, cacheControl
	return nil
}

func (s *store) Exists(_ context.Context, key string) (bool, error) { return s.get(key) != nil, nil }

func (s *store) List(_ context.Context, prefix string) ([]string, error) { return s.keys(prefix), nil }

func (s *store) Copy(_ context.Context, src, dst, _, cacheControl string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, ok := s.objects[src]
	if !ok {
		return fmt.Errorf("copy %s: %w", src, objstore.ErrNotFound)
	}
	s.objects[dst], s.caches[dst] = data, cacheControl
	return nil
}

// kafka starts an in-memory cluster with the output topic and returns its brokers and a producer.
func kafka(t *testing.T) (string, *kgo.Client) {
	t.Helper()
	c, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(1, worker.OutputTopic))
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
	return brokers, cl
}

// published reads the one event on the output topic.
func published(t *testing.T, brokers string) *mediav1.TranscodeEvent {
	t.Helper()
	cl, err := kafkax.NewClient(brokers, "test-reader", kgo.ConsumeTopics(worker.OutputTopic), kgo.FetchMaxWait(100*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	var records []*kgo.Record
	for len(records) == 0 && ctx.Err() == nil {
		records = cl.PollFetches(ctx).Records()
	}
	if len(records) != 1 {
		t.Fatalf("read %d records, want 1", len(records))
	}
	var ev mediav1.TranscodeEvent
	if err := proto.Unmarshal(records[0].Value, &ev); err != nil {
		t.Fatal(err)
	}
	return &ev
}

// readySample returns the sum of the ready samples of svp.transcode.duration, false without one.
func readySample(t *testing.T, reader *sdkmetric.ManualReader) (float64, bool) {
	t.Helper()
	var data metricdata.ResourceMetrics
	if err := reader.Collect(t.Context(), &data); err != nil {
		t.Fatal(err)
	}
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			if m.Name != "svp.transcode.duration" {
				continue
			}
			for _, p := range m.Data.(metricdata.Histogram[float64]).DataPoints {
				if v, _ := p.Attributes.Value(attribute.Key("outcome")); v.AsString() == "ready" && p.Count == 1 {
					return p.Sum, true
				}
			}
		}
	}
	return 0, false
}
