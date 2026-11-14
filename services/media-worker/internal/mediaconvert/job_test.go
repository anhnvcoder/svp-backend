package mediaconvert

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/mediaconvert/types"
	"go.opentelemetry.io/otel/trace"

	mediav1 "github.com/anhnvcoder/svp-backend/gen/go/svp/media/v1"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/transcode"
)

var update = flag.Bool("update", false, "rewrite testdata/create-job.json from the code")

// The sample job's identifiers: fixed, so the golden file is too.
const (
	sampleVideo       = "0190a6e4-7b2c-7d3e-9f40-000000000001"
	sampleVersion     = "0190a6e4-7b2c-7d3e-9f40-000000000002"
	sampleAttempt     = "0190a6e4-7b2c-7d3e-9f40-000000000003"
	sampleTraceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
)

// cliJSON writes v as the JSON the AWS CLI reads with --cli-input-json: the member names of the
// API, unset members left out, keys sorted, two-space indent.
func cliJSON(t *testing.T, v any) []byte {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var tree any
	if err := dec.Decode(&tree); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(prune(tree)); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// prune drops nulls, empty strings (unset enums) and the objects and lists left empty.
func prune(v any) any {
	switch v := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, x := range v {
			if x = prune(x); x != nil {
				out[k] = x
			}
		}
		if len(out) == 0 {
			return nil
		}
		return out
	case []any:
		var out []any
		for _, x := range v {
			if x = prune(x); x != nil {
				out = append(out, x)
			}
		}
		if len(out) == 0 {
			return nil
		}
		return out
	case string:
		if v == "" {
			return nil
		}
	}
	return v
}

func sampleBridge() *Bridge {
	return New(Config{QueueARN: testQueueARN, RoleARN: testRoleARN, UploadsBucket: testUploads, MediaBucket: testMedia}, nil, nil, nil, nil, nil)
}

func sampleRef() jobRef {
	return jobRef{videoID: sampleVideo, version: sampleVersion, attempt: sampleAttempt, traceparent: sampleTraceparent}
}

// sampleSource is the probe of the reference clip: 60 s of 1080x1920 at 30 fps with sound.
func sampleSource(t *testing.T) Source {
	t.Helper()
	src, reason, detail := Inspect(probeOf(1080, 1920, 0, 60, true).ProbeResults)
	if reason != mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_UNSPECIFIED {
		t.Fatalf("Inspect() = %v %s", reason, detail)
	}
	return src
}

// The sample job, byte for byte: what the bridge sends for the reference clip, and the file a
// person submits by hand in a sandbox account. go test -run TestSampleJob -update rewrites it.
func TestSampleJob(t *testing.T) {
	t.Parallel()
	got := cliJSON(t, sampleBridge().BuildJob(sampleRef(), sampleSource(t)))
	path := filepath.Join("testdata", "create-job.json")
	if *update {
		if err := os.WriteFile(path, got, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path) //nolint:gosec // a fixed file of testdata
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("CreateJobInput differs from %s:\n%s", path, got)
	}
}

// The traceparent of the job is the span the bridge works in; without one the key is left out.
func TestTraceparentOf(t *testing.T) {
	t.Parallel()
	ctx := traceContext(context.Background(), sampleTraceparent)
	if got := traceparentOf(ctx); got != sampleTraceparent {
		t.Errorf("traceparentOf() = %q, want %q", got, sampleTraceparent)
	}
	if got := traceparentOf(context.Background()); got != "" {
		t.Errorf("traceparentOf() without a span = %q", got)
	}
	if sc := trace.SpanContextFromContext(traceContext(context.Background(), "garbage")); sc.IsValid() {
		t.Errorf("a malformed traceparent gave span %v", sc)
	}
	ref := sampleRef()
	ref.traceparent = ""
	if _, ok := sampleBridge().BuildJob(ref, sampleSource(t)).UserMetadata[metaTraceparent]; ok {
		t.Error("job without a trace carries a traceparent")
	}
}

// outputSizes lists "<name modifier> <w>x<h>" of every output of a job, groups in order.
func outputSizes(in []types.OutputGroup) []string {
	var out []string
	for _, g := range in {
		for _, o := range g.Outputs {
			out = append(out, fmt.Sprintf("%s %dx%d", aws.ToString(o.NameModifier),
				aws.ToInt32(o.VideoDescription.Width), aws.ToInt32(o.VideoDescription.Height)))
		}
	}
	return out
}

// A source without sound gets a job without audio; a phone video stored landscape with a 90°
// rotation gets the ladder of its portrait display and automatic rotation.
func TestBuildJobFollowsTheSource(t *testing.T) {
	t.Parallel()
	b := sampleBridge()

	src, _, _ := Inspect(probeOf(1280, 720, 0, 10, false).ProbeResults)
	job := b.BuildJob(sampleRef(), src)
	if in := job.Settings.Inputs[0]; len(in.AudioSelectors) != 0 {
		t.Errorf("audio selectors %v for a source without audio", in.AudioSelectors)
	}
	for _, g := range job.Settings.OutputGroups {
		for _, o := range g.Outputs {
			if len(o.AudioDescriptions) != 0 {
				t.Errorf("output %q has audio", aws.ToString(o.NameModifier))
			}
		}
	}
	want := []string{"_360p 640x360", "_720p 1280x720", " 1280x720"}
	if got := outputSizes(job.Settings.OutputGroups); !slices.Equal(got, want) {
		t.Errorf("outputs %v, want %v", got, want)
	}

	src, _, _ = Inspect(probeOf(1920, 1080, 90, 10, true).ProbeResults)
	job = b.BuildJob(sampleRef(), src)
	if r := job.Settings.Inputs[0].VideoSelector.Rotate; r != types.InputRotateAuto {
		t.Errorf("rotate = %q, want AUTO", r)
	}
	want = []string{"_360p 360x640", "_720p 720x1280", "_1080p 1080x1920", " 720x1280"}
	if got := outputSizes(job.Settings.OutputGroups); !slices.Equal(got, want) {
		t.Errorf("outputs %v, want %v", got, want)
	}
	if len(job.Settings.Inputs[0].AudioSelectors) != 1 {
		t.Errorf("audio selectors %v, want one", job.Settings.Inputs[0].AudioSelectors)
	}
}

// timecodePattern is the pattern of InputClipping.EndTimecode in the MediaConvert API reference.
var timecodePattern = regexp.MustCompile(`^([01][0-9]|2[0-4]):[0-5][0-9]:[0-5][0-9][:;][0-9]{2}(@[0-9]+(\.[0-9]+)?(:[0-9]+)?)?$`)

// The clip ends on the last frame inside both the video track and the 3-minute cap, so the job
// never asks for a timecode outside the input (error 1060) and never encodes more than 3 minutes.
// Above 100 fps a two-digit FF ends the clip at frame 99 of its second, the accepted cost: 60 s at
// 120 fps ends on frame 7179, not 7199, dropping 20 frames; never more than fps-100.
func TestEndTimecode(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		duration time.Duration
		fps      float64
		want     string
	}{
		{60 * time.Second, 30, "00:00:59:29"},
		{180500 * time.Millisecond, 30, "00:02:59:29"},
		{2 * time.Second, 25, "00:00:01:24"},
		{60 * time.Second, 30000.0 / 1001, "00:00:59:27"},
		{1500 * time.Millisecond, 60, "00:00:01:29"},
		{2 * time.Second, 100, "00:00:01:99"},
		{60 * time.Second, 120, "00:00:59:99"},
		{60 * time.Second, 120000.0 / 1001, "00:00:59:99"},
		{1500 * time.Millisecond, 120, "00:00:01:59"},
	} {
		if got := endTimecode(Source{Duration: tt.duration, FPS: tt.fps}); got != tt.want {
			t.Errorf("endTimecode(%v at %.3f fps) = %s, want %s", tt.duration, tt.fps, got, tt.want)
		}
	}

	// Every frame rate Inspect lets through, at lengths ending anywhere in a second.
	rates := []float64{24000.0 / 1001, 30000.0 / 1001, 60000.0 / 1001, 120000.0 / 1001}
	for fps := 1; fps <= 120; fps++ {
		rates = append(rates, float64(fps))
	}
	for _, fps := range rates {
		for ms := 1000; ms <= 181_000; ms += 997 {
			src := Source{Duration: time.Duration(ms) * time.Millisecond, FPS: fps}
			got := endTimecode(src)
			var h, m, s, ff int
			if _, err := fmt.Sscanf(got, "%d:%d:%d:%d", &h, &m, &s, &ff); err != nil || !timecodePattern.MatchString(got) {
				t.Fatalf("endTimecode(%v at %.3f fps) = %q, not a timecode the API takes", src.Duration, fps, got)
			}
			nominal := int(math.Round(fps))
			named := (h*3600+m*60+s)*nominal + ff
			if lost := endFrame(src) - named; ff >= nominal || lost < 0 || lost > max(nominal-100, 0) {
				t.Fatalf("endTimecode(%v at %.3f fps) = %s names frame %d for the last frame %d",
					src.Duration, fps, got, named, endFrame(src))
			}
		}
	}
}

// Inspect applies the limits of package transcode to what Probe reports.
func TestInspect(t *testing.T) {
	t.Parallel()
	invalid := mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT
	exceeded := mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_DURATION_EXCEEDED
	ok := mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_UNSPECIFIED
	edit := func(f func(c *types.Container)) []types.ProbeResult {
		out := probeOf(1080, 1920, 0, 60, true)
		f(out.ProbeResults[0].Container)
		return out.ProbeResults
	}
	video := func(c *types.Container) *types.VideoProperties { return c.Tracks[0].VideoProperties }
	tests := []struct {
		name    string
		results []types.ProbeResult
		want    mediav1.TranscodeFailureReason
	}{
		{"valid", probeOf(1080, 1920, 0, 60, true).ProbeResults, ok},
		{"181 s within slack", edit(func(c *types.Container) { c.Duration = aws.Float64(181) }), ok},
		{"no result", nil, invalid},
		{"no container", []types.ProbeResult{{}}, invalid},
		{"no duration", edit(func(c *types.Container) { c.Duration = nil }), invalid},
		{"no video track", edit(func(c *types.Container) { c.Tracks = c.Tracks[1:] }), invalid},
		{"long side 4097", edit(func(c *types.Container) { video(c).Height = aws.Int32(4097) }), invalid},
		{"no size", edit(func(c *types.Container) { video(c).Width = nil }), invalid},
		{"120 fps", edit(func(c *types.Container) { video(c).FrameRate.Numerator = aws.Int32(120) }), ok},
		{"fps over 120", edit(func(c *types.Container) { video(c).FrameRate.Numerator = aws.Int32(240) }), invalid},
		{"no frame rate", edit(func(c *types.Container) { video(c).FrameRate = nil }), invalid},
		{"over 181 s", edit(func(c *types.Container) { c.Duration = aws.Float64(200) }), exceeded},
		{"invalid beats duration", edit(func(c *types.Container) {
			c.Duration = aws.Float64(500)
			video(c).Width = aws.Int32(5000)
		}), invalid},
	}
	for _, tt := range tests {
		if _, got, detail := Inspect(tt.results); got != tt.want {
			t.Errorf("%s: Inspect() = %v (%s), want %v", tt.name, got, detail, tt.want)
		}
	}

	src, _, _ := Inspect(probeOf(1920, 1080, 270, 30, false).ProbeResults)
	if src.Width != 1080 || src.Height != 1920 || src.Audio || src.Duration != 30*time.Second || src.FPS != 30 {
		t.Errorf("rotated source = %+v, want 1080x1920 without audio, 30 s at 30 fps", src)
	}
	src, _, _ = Inspect(probeOf(1920, 1080, 180, 30, true).ProbeResults)
	if src.Width != 1920 || src.Height != 1080 {
		t.Errorf("upside-down source = %dx%d, want 1920x1080", src.Width, src.Height)
	}
}

// completedJob is the sample job as the fake completes it.
func completedJob(t *testing.T) *types.Job {
	t.Helper()
	store := newFakeStore()
	mc := newFakeMC(store)
	out, err := mc.CreateJob(t.Context(), sampleBridge().BuildJob(sampleRef(), sampleSource(t)))
	if err != nil {
		t.Fatal(err)
	}
	mc.complete(t, aws.ToString(out.Job.Id))
	return out.Job
}

// The sizes MediaConvert reports, in whatever order, go to the step with the same short side.
func TestJobRenditions(t *testing.T) {
	t.Parallel()
	job := completedJob(t)
	got, err := JobRenditions(job)
	if err != nil {
		t.Fatal(err)
	}
	want := []transcode.Rendition{
		{Name: "360p", Width: 360, Height: 640, Bitrate: 800_000},
		{Name: "720p", Width: 720, Height: 1280, Bitrate: 2_500_000},
		{Name: "1080p", Width: 1080, Height: 1920, Bitrate: 5_000_000},
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("JobRenditions() = %v, want %v", got, want)
	}

	broken := map[string]func(j *types.Job){
		"a size missing": func(j *types.Job) {
			d := j.OutputGroupDetails[0].OutputDetails
			j.OutputGroupDetails[0].OutputDetails = d[1:]
		},
		"a size off the ladder": func(j *types.Job) {
			j.OutputGroupDetails[0].OutputDetails[0].VideoDetails.WidthInPx = aws.Int32(400)
		},
		"an output outside the ladder": func(j *types.Job) {
			j.Settings.OutputGroups[0].Outputs[0].NameModifier = aws.String("_480p")
		},
		"no output detail": func(j *types.Job) { j.OutputGroupDetails = nil },
	}
	for name, f := range broken {
		j := completedJob(t)
		f(j)
		if rs, err := JobRenditions(j); err == nil {
			t.Errorf("%s: JobRenditions() = %v, want an error", name, rs)
		}
	}
}

func TestParseEvent(t *testing.T) {
	t.Parallel()
	good := stateChangeOf("1700000000000-abc123", types.JobStatusComplete)
	if id, err := parseEvent(&good); err != nil || id != "1700000000000-abc123" {
		t.Errorf("parseEvent() = %q, %v", id, err)
	}
	for name, body := range map[string]string{
		"not JSON":       "hello",
		"other source":   strings.Replace(good, `"aws.mediaconvert"`, `"aws.s3"`, 1),
		"other type":     strings.Replace(good, `Job State Change`, `Job Progress`, 1),
		"no job ID":      strings.Replace(good, `"jobId":"1700000000000-abc123"`, `"jobId":""`, 1),
		"path in job ID": strings.Replace(good, `"jobId":"1700000000000-abc123"`, `"jobId":"../queues/x"`, 1),
	} {
		if id, err := parseEvent(&body); err == nil {
			t.Errorf("%s: parseEvent() = %q, want an error", name, id)
		}
	}
	if _, err := parseEvent(nil); err == nil {
		t.Error("parseEvent(nil) succeeded")
	}
}

// Only a job of the environment's queue, with canonical metadata and every output under its own
// attempt directory, is acted on.
func TestCheckJob(t *testing.T) {
	t.Parallel()
	b := sampleBridge()
	if ref, err := b.checkJob(completedJob(t)); err != nil || ref != sampleRef() {
		t.Fatalf("checkJob() = %+v, %v; want %+v", ref, err, sampleRef())
	}
	for name, f := range map[string]func(j *types.Job){
		"other queue": func(j *types.Job) { j.Queue = aws.String(testQueueARN + "x") },
		"no metadata": func(j *types.Job) { j.UserMetadata = nil },
		"version not a UUID": func(j *types.Job) {
			j.UserMetadata = map[string]string{metaVideoID: sampleVideo, metaVersion: "v1", metaAttempt: sampleAttempt}
		},
		"HLS elsewhere": func(j *types.Job) {
			j.Settings.OutputGroups[0].OutputGroupSettings.HlsGroupSettings.Destination = aws.String("s3://" + testMedia + "/media/" + sampleVideo + "/index")
		},
		"thumbnail deeper": func(j *types.Job) {
			j.Settings.OutputGroups[1].OutputGroupSettings.FileGroupSettings.Destination =
				aws.String(b.attemptDir(sampleRef()) + "x/thumb")
		},
		"other bucket": func(j *types.Job) {
			j.Settings.OutputGroups[1].OutputGroupSettings.FileGroupSettings.Destination =
				aws.String(strings.Replace(b.attemptDir(sampleRef()), testMedia, testUploads, 1) + "thumb")
		},
		"no settings": func(j *types.Job) { j.Settings = nil },
	} {
		j := completedJob(t)
		f(j)
		if _, err := b.checkJob(j); err == nil {
			t.Errorf("%s: checkJob() succeeded", name)
		}
	}
}

// MediaConvert's input errors fail the version as INVALID_INPUT, any other as RETRIES_EXHAUSTED.
func TestJobFailure(t *testing.T) {
	t.Parallel()
	for code, want := range map[int32]mediav1.TranscodeFailureReason{
		1010: mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT,
		1060: mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT,
		1076: mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT,
		1401: mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_RETRIES_EXHAUSTED,
		1999: mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_RETRIES_EXHAUSTED,
		3000: mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_RETRIES_EXHAUSTED,
	} {
		job := &types.Job{Id: aws.String("1700000000000-abc123"), ErrorCode: aws.Int32(code), ErrorMessage: aws.String("m")}
		if got, detail := jobFailure(job); got != want || !strings.Contains(detail, fmt.Sprint(code)) {
			t.Errorf("code %d: %v %q, want %v", code, got, detail, want)
		}
	}
}
