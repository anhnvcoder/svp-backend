package replay

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"maps"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"

	"github.com/anhnvcoder/svp-backend/internal/kafkax"
)

const (
	source = "video.lifecycle.v1"
	dlq    = source + kafkax.DLQSuffix
	other  = "other.v1"
	// marker is in every key, value and header value of the tests' records, so a log line that
	// carries any of their bytes shows.
	marker = "SECRET-MARKER"
)

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// lines returns the JSON log lines with message msg.
func (b *lockedBuffer) lines(t *testing.T, msg string) []map[string]any {
	t.Helper()
	var out []map[string]any
	for line := range strings.SplitSeq(strings.TrimSpace(b.String()), "\n") {
		var rec map[string]any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("log line %q is not JSON: %v", line, err)
		}
		if rec["msg"] == msg {
			out = append(out, rec)
		}
	}
	return out
}

// cluster starts an in-memory Kafka with the given topics of one partition each and returns its
// broker list.
func cluster(t *testing.T, partitions int32, topics ...string) string {
	t.Helper()
	c, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(partitions, topics...))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return strings.Join(c.ListenAddrs(), ",")
}

// seed writes rs as they are, partition and timestamp included.
func seed(t *testing.T, brokers string, rs ...*kgo.Record) {
	t.Helper()
	cl, err := kafkax.NewClient(brokers, "test-seed", kgo.RecordPartitioner(kgo.ManualPartitioner()))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	if err := cl.ProduceSync(ctx, rs...).FirstErr(); err != nil {
		t.Fatal(err)
	}
}

// readTopic returns what topic holds: it waits up to a long deadline for want records, then reads
// a short window more, so a record beyond want shows up as an extra. A slow reader only makes the
// wait longer.
func readTopic(t *testing.T, brokers, topic string, want int) []*kgo.Record {
	t.Helper()
	cl, err := kafkax.NewClient(brokers, "test-reader", kgo.ConsumeTopics(topic),
		kgo.FetchMaxWait(100*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	var out []*kgo.Record
	poll := func(wait time.Duration, until func() bool) {
		ctx, cancel := context.WithTimeout(t.Context(), wait)
		defer cancel()
		for !until() && ctx.Err() == nil {
			out = append(out, cl.PollFetches(ctx).Records()...)
		}
	}
	poll(15*time.Second, func() bool { return len(out) >= want })
	poll(500*time.Millisecond, func() bool { return false })
	return out
}

// dead is a record of the dead-letter topic as kafkax writes it: the original headers, then the
// dlq-* ones. A non-empty name is the dlq-topic header; group is dlq-group.
func dead(name, group string, i int) *kgo.Record {
	headers := []kgo.RecordHeader{
		{Key: "traceparent", Value: []byte("00-" + marker + "-01")},
		{Key: "x-first", Value: []byte(marker + "-a")},
		{Key: kafkax.HeaderDLQReason, Value: []byte(kafkax.ReasonPermanent)},
		{Key: "x-second", Value: []byte(marker + "-b")},
		{Key: kafkax.HeaderDLQError, Value: []byte(marker + " error")},
	}
	if name != "" {
		headers = append(headers, kgo.RecordHeader{Key: kafkax.HeaderDLQTopic, Value: []byte(name)})
	}
	if group != "" {
		headers = append(headers, kgo.RecordHeader{Key: kafkax.HeaderDLQGroup, Value: []byte(group)})
	}
	n := strconv.Itoa(i)
	return &kgo.Record{Topic: dlq, Key: []byte(marker + "-key-" + n), Value: []byte(marker + "-value-" + n),
		Headers: headers}
}

func config(brokers string) Config {
	return Config{Brokers: brokers, ClientID: "test-replay", From: dlq, Partition: Unset,
		StartOffset: Unset, EndOffset: Unset}
}

func replay(t *testing.T, cfg Config) (Summary, *lockedBuffer, error) {
	t.Helper()
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	logs := &lockedBuffer{}
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	sum, err := Run(ctx, cfg, slog.New(slog.NewJSONHandler(logs, nil)))
	return sum, logs, err
}

func values(rs []*kgo.Record) []string {
	out := make([]string, 0, len(rs))
	for _, r := range rs {
		out = append(out, strings.TrimPrefix(string(r.Value), marker+"-value-"))
	}
	return out
}

func equal(a, b []string) bool { return strings.Join(a, ",") == strings.Join(b, ",") }

// The copy has the key and value of the dead-letter record byte for byte, its headers in order
// without the dlq-* ones, a timestamp of the replay, and goes to the dlq-topic header's topic.
func TestCopiesRecordToItsSourceTopic(t *testing.T) {
	brokers := cluster(t, 1, source, dlq, other)
	in := dead(source, "media-worker", 0)
	in.Timestamp = time.Now().Add(-48 * time.Hour)
	seed(t, brokers, in)
	before := time.Now()

	sum, _, err := replay(t, config(brokers))
	if err != nil {
		t.Fatal(err)
	}
	if sum.Replayed != 1 || sum.Skipped != 0 || sum.DryRun != 0 || sum.LastReplayed[0] != 0 || sum.Resume != nil {
		t.Errorf("summary = %+v, want 1 replayed at offset 0", sum)
	}
	got := readTopic(t, brokers, source, 1)
	if len(got) != 1 {
		t.Fatalf("%d records in %s, want 1", len(got), source)
	}
	out := got[0]
	if !bytes.Equal(out.Key, in.Key) || !bytes.Equal(out.Value, in.Value) {
		t.Errorf("copy key, value = %q, %q, want %q, %q", out.Key, out.Value, in.Key, in.Value)
	}
	want := []kgo.RecordHeader{in.Headers[0], in.Headers[1], in.Headers[3]}
	if len(out.Headers) != len(want) {
		t.Fatalf("copy headers = %v, want %v", out.Headers, want)
	}
	for i, h := range out.Headers {
		if h.Key != want[i].Key || !bytes.Equal(h.Value, want[i].Value) {
			t.Errorf("copy header %d = %s=%q, want %s=%q", i, h.Key, h.Value, want[i].Key, want[i].Value)
		}
	}
	if out.Timestamp.Before(before.Add(-time.Second)) {
		t.Errorf("copy timestamp = %v, want the time of the replay (after %v)", out.Timestamp, before)
	}
	if n := len(readTopic(t, brokers, other, 0)); n != 0 {
		t.Errorf("%d records in %s, want 0", n, other)
	}
}

// --to sends every record there, whatever its dlq-topic header says, and a record without the
// header is skipped only when there is no --to.
func TestToOverridesHeaderAndMissingHeaderIsSkipped(t *testing.T) {
	brokers := cluster(t, 1, source, dlq, other)
	seed(t, brokers, dead(source, "", 0), dead("", "", 1))

	sum, logs, err := replay(t, config(brokers))
	if err != nil {
		t.Fatal(err)
	}
	if sum.Replayed != 1 || sum.Skipped != 1 {
		t.Errorf("summary = %+v, want 1 replayed, 1 skipped", sum)
	}
	if got := values(readTopic(t, brokers, source, 1)); !equal(got, []string{"0"}) {
		t.Errorf("%s = %v, want [0]", source, got)
	}
	lines := logs.lines(t, "dlq record")
	if len(lines) != 2 || lines[1]["result"] != ResultSkipped || lines[1]["reason"] != "no-destination" {
		t.Errorf("record lines = %v, want the second skipped for no-destination", lines)
	}

	cfg := config(brokers)
	cfg.To = other
	sum, _, err = replay(t, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if sum.Replayed != 2 || sum.Skipped != 0 {
		t.Errorf("summary with --to = %+v, want 2 replayed", sum)
	}
	if got := values(readTopic(t, brokers, other, 2)); !equal(got, []string{"0", "1"}) {
		t.Errorf("%s = %v, want [0 1]", other, got)
	}
}

func TestOffsetRange(t *testing.T) {
	brokers := cluster(t, 1, source, dlq)
	for i := range 5 {
		seed(t, brokers, dead(source, "", i))
	}
	cfg := config(brokers)
	cfg.StartOffset, cfg.EndOffset = 1, 3
	sum, _, err := replay(t, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if sum.Replayed != 2 || sum.LastReplayed[0] != 2 {
		t.Errorf("summary = %+v, want 2 replayed, last at offset 2", sum)
	}
	if got := values(readTopic(t, brokers, source, 2)); !equal(got, []string{"1", "2"}) {
		t.Errorf("%s = %v, want [1 2]", source, got)
	}
}

// --since and --until select by the timestamp of the dead-letter record.
func TestTimeRange(t *testing.T) {
	brokers := cluster(t, 1, source, dlq)
	base := time.Now().Add(-time.Hour).Truncate(time.Second)
	for i := range 5 {
		r := dead(source, "", i)
		r.Timestamp = base.Add(time.Duration(i) * time.Minute)
		seed(t, brokers, r)
	}
	cfg := config(brokers)
	cfg.Since, cfg.Until = base.Add(time.Minute), base.Add(3*time.Minute)
	sum, logs, err := replay(t, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if sum.Replayed != 2 {
		t.Errorf("summary = %+v, want 2 replayed", sum)
	}
	// The end --until selected is the --end-offset that repeats the range by offsets.
	if lines := logs.lines(t, "dlq replay finished"); len(lines) != 1 || lines[0]["end"] != "0@3" {
		t.Errorf("summary lines = %v, want end 0@3", lines)
	}
	if got := values(readTopic(t, brokers, source, 2)); !equal(got, []string{"1", "2"}) {
		t.Errorf("%s = %v, want [1 2]", source, got)
	}

	// A time past every record selects nothing.
	cfg.Since, cfg.Until = base.Add(time.Hour), time.Time{}
	sum, _, err = replay(t, cfg)
	if err != nil || sum.Replayed+sum.Skipped+sum.DryRun != 0 {
		t.Errorf("since past the end: summary = %+v, err = %v, want nothing", sum, err)
	}
}

func TestGroupFilter(t *testing.T) {
	brokers := cluster(t, 1, source, dlq)
	seed(t, brokers, dead(source, "feed-service", 0), dead(source, "media-worker", 1), dead(source, "", 2))
	cfg := config(brokers)
	cfg.Group = "media-worker"
	sum, _, err := replay(t, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if sum.Replayed != 1 || sum.Skipped != 2 {
		t.Errorf("summary = %+v, want 1 replayed, 2 skipped", sum)
	}
	if got := values(readTopic(t, brokers, source, 1)); !equal(got, []string{"1"}) {
		t.Errorf("%s = %v, want [1]", source, got)
	}
}

func TestPartitionFilter(t *testing.T) {
	brokers := cluster(t, 2, source, dlq)
	r0, r1 := dead(source, "", 0), dead(source, "", 1)
	r0.Partition, r1.Partition = 0, 1
	seed(t, brokers, r0, r1)
	cfg := config(brokers)
	cfg.Partition = 1
	sum, _, err := replay(t, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if sum.Replayed != 1 || sum.LastReplayed[1] != 0 || len(sum.LastReplayed) != 1 {
		t.Errorf("summary = %+v, want 1 replayed from partition 1", sum)
	}
	if got := values(readTopic(t, brokers, source, 1)); !equal(got, []string{"1"}) {
		t.Errorf("%s = %v, want [1]", source, got)
	}

	cfg.Partition = 7
	if _, _, err := replay(t, cfg); err == nil || !strings.Contains(err.Error(), "no partition 7") {
		t.Errorf("missing partition: err = %v", err)
	}
}

func TestDryRunProducesNothing(t *testing.T) {
	brokers := cluster(t, 1, source, dlq)
	seed(t, brokers, dead(source, "", 0), dead("", "", 1))
	cfg := config(brokers)
	cfg.DryRun = true
	sum, _, err := replay(t, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if sum.DryRun != 1 || sum.Skipped != 1 || sum.Replayed != 0 {
		t.Errorf("summary = %+v, want 1 dry run, 1 skipped", sum)
	}
	if n := len(readTopic(t, brokers, source, 0)); n != 0 {
		t.Errorf("%d records in %s, want 0", n, source)
	}
}

// A run writing to the views topic warns once, dry run included; other destinations and skipped
// records do not warn.
func TestViewsDestinationWarnsOnce(t *testing.T) {
	const warning = "dlq replay counts views again"
	brokers := cluster(t, 1, source, viewsTopic, dlq)
	seed(t, brokers, dead(source, "", 0), dead(viewsTopic, "", 1), dead(viewsTopic, "", 2))
	for _, dryRun := range []bool{true, false} {
		cfg := config(brokers)
		cfg.DryRun = dryRun
		if _, logs, err := replay(t, cfg); err != nil {
			t.Fatal(err)
		} else if n := len(logs.lines(t, warning)); n != 1 {
			t.Errorf("dry run %v: %d warnings, want 1", dryRun, n)
		}
	}
	if n := len(readTopic(t, brokers, viewsTopic, 2)); n != 2 {
		t.Errorf("%d records in %s, want 2", n, viewsTopic)
	}

	cfg := config(brokers)
	cfg.Group = "no-such-group"
	if _, logs, err := replay(t, cfg); err != nil {
		t.Fatal(err)
	} else if n := len(logs.lines(t, warning)); n != 0 {
		t.Errorf("skipped records: %d warnings, want 0", n)
	}
	cfg = config(brokers)
	cfg.To = other
	cfg.DryRun = true
	if _, logs, err := replay(t, cfg); err != nil {
		t.Fatal(err)
	} else if n := len(logs.lines(t, warning)); n != 0 {
		t.Errorf("--to %s: %d warnings, want 0", other, n)
	}
}

// The first produce error ends the run: nothing after it is written, and the summary resumes at
// the record that failed.
func TestProduceErrorStopsAndNamesResumeOffset(t *testing.T) {
	brokers := cluster(t, 1, source, dlq)
	seed(t, brokers, dead(source, "", 0), dead("missing.v1", "", 1), dead(source, "", 2))

	sum, logs, err := replay(t, config(brokers))
	if err == nil {
		t.Fatal("no error, want the produce error of offset 1")
	}
	if sum.Replayed != 1 || sum.Resume[0] != 1 || len(sum.Resume) != 1 {
		t.Errorf("summary = %+v, want 1 replayed, resume at 0@1", sum)
	}
	if got := values(readTopic(t, brokers, source, 1)); !equal(got, []string{"0"}) {
		t.Errorf("%s = %v, want [0]", source, got)
	}
	lines := logs.lines(t, "dlq replay stopped")
	if len(lines) != 1 || lines[0]["resume_from"] != "0@1" || lines[0]["last_replayed"] != "0@0" ||
		lines[0]["end"] != "0@3" {
		t.Errorf("summary lines = %v, want resume_from 0@1, end 0@3", lines)
	}
}

func TestEmptyRange(t *testing.T) {
	brokers := cluster(t, 1, source, dlq)
	sum, logs, err := replay(t, config(brokers))
	if err != nil {
		t.Fatal(err)
	}
	if sum.Replayed+sum.Skipped+sum.DryRun != 0 {
		t.Errorf("empty topic: summary = %+v", sum)
	}
	if lines := logs.lines(t, "dlq replay finished"); len(lines) != 1 || lines[0]["replayed"] != float64(0) {
		t.Errorf("summary lines = %v, want one with 0 replayed", lines)
	}

	seed(t, brokers, dead(source, "", 0))
	cfg := config(brokers)
	cfg.StartOffset, cfg.EndOffset = 1, 1
	if sum, _, err := replay(t, cfg); err != nil || sum.Replayed != 0 {
		t.Errorf("empty range: summary = %+v, err = %v", sum, err)
	}
}

// The range ends at the high watermark of the start: a run that writes into the topic it reads
// replays what was there and stops.
func TestRecordsArrivingDuringTheRunAreNotReplayed(t *testing.T) {
	brokers := cluster(t, 1, source, dlq)
	seed(t, brokers, dead(source, "", 0), dead(source, "", 1))
	cfg := config(brokers)
	cfg.To = dlq
	sum, _, err := replay(t, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if sum.Replayed != 2 {
		t.Errorf("summary = %+v, want 2 replayed", sum)
	}
}

// Logs carry offsets, lengths and header names, never bytes of a key, a value or a header value.
func TestLogsCarryNoRecordBytes(t *testing.T) {
	brokers := cluster(t, 1, source, dlq)
	seed(t, brokers, dead(source, "media-worker", 0), dead("missing.v1", "", 1))
	_, logs, err := replay(t, config(brokers))
	if err == nil {
		t.Fatal("no error, want the produce error of offset 1")
	}
	if strings.Contains(logs.String(), marker) {
		t.Errorf("logs carry record bytes:\n%s", logs)
	}
	lines := logs.lines(t, "dlq record")
	if len(lines) != 2 || lines[0]["key_bytes"] != float64(len(dead("", "", 0).Key)) ||
		!strings.Contains(strings.Join(anyStrings(lines[0]["headers"]), ","), "traceparent,x-first") ||
		lines[1]["result"] != "failed" {
		t.Errorf("record lines = %v", lines)
	}
}

func anyStrings(v any) []string {
	list, _ := v.([]any)
	out := make([]string, 0, len(list))
	for _, s := range list {
		str, _ := s.(string)
		out = append(out, str)
	}
	return out
}

// svp.dlq.replay.records counts each record by from, to and result.
func TestRecordsCounter(t *testing.T) {
	reader := sdkmetric.NewManualReader()
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))
	prev := otel.GetMeterProvider()
	otel.SetMeterProvider(mp)
	t.Cleanup(func() {
		otel.SetMeterProvider(prev)
		_ = mp.Shutdown(context.Background())
	})
	brokers := cluster(t, 1, source, dlq, other)
	seed(t, brokers, dead(source, "", 0), dead(source, "", 1), dead("", "", 2))
	if _, _, err := replay(t, config(brokers)); err != nil {
		t.Fatal(err)
	}
	cfg := config(brokers)
	cfg.To, cfg.DryRun = other, true
	if _, _, err := replay(t, cfg); err != nil {
		t.Fatal(err)
	}

	var data metricdata.ResourceMetrics
	if err := reader.Collect(context.Background(), &data); err != nil {
		t.Fatal(err)
	}
	got := map[string]int64{}
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			sum, ok := m.Data.(metricdata.Sum[int64])
			if m.Name != "svp.dlq.replay.records" || !ok {
				continue
			}
			for _, p := range sum.DataPoints {
				from, _ := p.Attributes.Value("from")
				to, _ := p.Attributes.Value("to")
				result, _ := p.Attributes.Value("result")
				if p.Attributes.Len() != 3 {
					t.Errorf("attributes = %v, want from, to, result", p.Attributes)
				}
				got[from.AsString()+">"+to.AsString()+":"+result.AsString()] = p.Value
			}
		}
	}
	want := map[string]int64{
		dlq + ">" + source + ":replayed": 2,
		dlq + ">:skipped":                1,
		dlq + ">" + other + ":dry_run":   3,
	}
	if !maps.Equal(got, want) {
		t.Errorf("svp.dlq.replay.records = %v, want %v", got, want)
	}
}

func TestValidate(t *testing.T) {
	valid := config("unused")
	for name, change := range map[string]func(*Config){
		"no from":           func(c *Config) { c.From = "" },
		"from not dlq":      func(c *Config) { c.From = source },
		"from only suffix":  func(c *Config) { c.From = kafkax.DLQSuffix },
		"negative part":     func(c *Config) { c.Partition = -2 },
		"negative offset":   func(c *Config) { c.StartOffset = -5 },
		"start past end":    func(c *Config) { c.StartOffset, c.EndOffset = 4, 3 },
		"offsets and times": func(c *Config) { c.StartOffset, c.Since = 1, time.Now() },
		"until before since": func(c *Config) {
			c.Since, c.Until = time.Now(), time.Now().Add(-time.Minute)
		},
	} {
		cfg := valid
		change(&cfg)
		if err := cfg.Validate(); err == nil {
			t.Errorf("%s: Validate accepted %+v", name, cfg)
		}
	}
	if err := valid.Validate(); err != nil {
		t.Errorf("valid config: %v", err)
	}
}
