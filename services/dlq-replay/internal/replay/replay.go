// Package replay copies records of a dead-letter topic back to the topic they came from, for the
// dlq-replay command. An operator runs it once the cause that sent records to the dead-letter
// topic is fixed (a deploy, a broker back), so the records the consumers gave up on are handled
// again instead of being lost.
//
// A run reads one dead-letter topic by assigning its partitions directly: no consumer group and
// no commit, so a run leaves no state on the broker, two runs never share work and a run can be
// repeated over any range. The range of each partition is fixed when the run starts, its end at
// the high watermark by default, so records dead-lettered while the run goes, or a run that writes
// into the topic it reads, never make it run forever.
//
// Key, value and headers are copied byte for byte: the consumers decode the value as the producer
// wrote it, check the key against it, and follow the trace headers back to the original request.
// The headers the dead-letter step added (names starting with "dlq-") are dropped, so the copy
// reads as the original record and, should it fail again, gets fresh ones. The copy gets the time
// of the replay as its timestamp, so the retention of the destination counts from the replay and
// a record dead-lettered days ago is not deleted at once, and goes to the partition the default
// partitioner picks for its key, as the original producer's did.
//
// One destination is not safe to replay twice: engagement-service drops a repeated view by its
// offset, not its event id, so every copy of a view is counted. A run that writes to
// engagement.views.v1 logs a warning; each range of it is replayed once, its summary line the record.
//
// Records are produced one at a time and the first produce error ends the run: the summary then
// names the offset to start the next run from, and nothing past it was written. Every summary line
// also names the end (exclusive) of each partition's range, so a run that stopped resumes with
// --start-offset and --end-offset alone, even when it selected its range by time. Logs carry
// offsets, destinations, key lengths and header names, never the bytes of a key, a value or a
// header value: those hold user data.
package replay

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"maps"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/kmsg"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"

	"github.com/anhnvcoder/svp-backend/internal/kafkax"
)

// Unset marks an offset or partition field of Config that was not given.
const Unset = -1

// Results of one record, the result attribute of the records counter.
const (
	ResultReplayed = "replayed"
	ResultSkipped  = "skipped"
	ResultDryRun   = "dry_run"
)

// produceTimeout bounds the produce of one record. Past it the run stops, as on any produce
// error, rather than holding on a broker that does not answer.
const produceTimeout = 30 * time.Second

// viewsTopic is the destination whose consumer counts a replayed copy again (see the package doc).
const viewsTopic = "engagement.views.v1"

const meterName = "github.com/anhnvcoder/svp-backend/services/dlq-replay/internal/replay"

// Config selects the records of one run.
type Config struct {
	// Brokers is the comma-separated broker list, as kafkax.NewClient takes it.
	Brokers string
	// ClientID identifies the run's clients to the brokers.
	ClientID string
	// From is the dead-letter topic to read; it must end in kafkax.DLQSuffix.
	From string
	// To, when set, is the destination of every record. Empty: each record goes to the topic its
	// dlq-topic header names, and a record without one is skipped.
	To string
	// Partition limits the run to one partition of From; Unset reads all.
	Partition int32
	// StartOffset (inclusive) and EndOffset (exclusive) bound each partition read; Unset means
	// the first offset still on the log and the high watermark at the start of the run.
	StartOffset, EndOffset int64
	// Since (inclusive) and Until (exclusive) bound the records by their timestamp in From, the
	// time they were dead-lettered, through the broker's offset-for-time lookup. They cannot be
	// combined with the offsets.
	Since, Until time.Time
	// Group, when set, keeps only the records whose dlq-group header equals it.
	Group string
	// DryRun reads and filters as a real run does, and produces nothing.
	DryRun bool
}

// Validate checks c the way the command checks its flags.
func (c Config) Validate() error {
	switch {
	case c.From == "":
		return errors.New("--from is required")
	case !strings.HasSuffix(c.From, kafkax.DLQSuffix) || c.From == kafkax.DLQSuffix:
		return fmt.Errorf("--from %q is not a dead-letter topic: its name must end in %q", c.From, kafkax.DLQSuffix)
	case c.Partition < Unset:
		return errors.New("--partition must not be negative")
	case c.StartOffset < Unset || c.EndOffset < Unset:
		return errors.New("--start-offset and --end-offset must not be negative")
	case c.StartOffset != Unset && c.EndOffset != Unset && c.StartOffset > c.EndOffset:
		return errors.New("--start-offset must not be past --end-offset")
	case (c.StartOffset != Unset || c.EndOffset != Unset) && (!c.Since.IsZero() || !c.Until.IsZero()):
		return errors.New("--since and --until cannot be combined with --start-offset or --end-offset")
	case !c.Since.IsZero() && !c.Until.IsZero() && c.Until.Before(c.Since):
		return errors.New("--until must not be before --since")
	}
	return nil
}

// Summary is what a run did.
type Summary struct {
	Replayed, Skipped, DryRun int
	// LastReplayed is the offset of the last record produced, per partition of From.
	LastReplayed map[int32]int64
	// Resume, set when the run stopped before the end of its range, is the offset to start the
	// next run from, per partition left unfinished.
	Resume map[int32]int64
}

// span is the offset range [start, end) to read from one partition.
type span struct{ start, end int64 }

// Run replays the records cfg selects and logs one line per record and a summary line to logger.
// It returns the summary and, when the run stopped early, why: a produce or fetch error, or ctx
// canceled. cfg must be valid (Validate).
func Run(ctx context.Context, cfg Config, logger *slog.Logger) (Summary, error) {
	sum := Summary{LastReplayed: map[int32]int64{}}
	counter, err := otel.Meter(meterName).Int64Counter("svp.dlq.replay.records",
		metric.WithDescription("Records of a dead-letter topic handled by dlq-replay, by destination and result."))
	if err != nil {
		return sum, fmt.Errorf("create records counter: %w", err)
	}
	cl, err := kafkax.NewClient(cfg.Brokers, cfg.ClientID)
	if err != nil {
		return sum, err
	}
	defer cl.Close()

	spans, err := ranges(ctx, cl, cfg)
	if err != nil {
		return sum, err
	}
	r := &run{cfg: cfg, cl: cl, logger: logger, counter: counter, sum: &sum, next: map[int32]int64{}}
	err = r.replay(ctx, spans)
	if err != nil {
		sum.Resume = r.next
	}
	ends := make(map[int32]int64, len(spans))
	for p, s := range spans {
		ends[p] = s.end
	}
	attrs := []slog.Attr{slog.String("from", cfg.From), slog.Int("replayed", sum.Replayed),
		slog.Int("skipped", sum.Skipped), slog.Int("dry_run", sum.DryRun),
		slog.String("last_replayed", offsets(sum.LastReplayed)), slog.String("end", offsets(ends))}
	if err != nil {
		attrs = append(attrs, slog.String("resume_from", offsets(sum.Resume)))
		logger.LogAttrs(ctx, slog.LevelWarn, "dlq replay stopped", attrs...)
		return sum, err
	}
	logger.LogAttrs(ctx, slog.LevelInfo, "dlq replay finished", attrs...)
	return sum, nil
}

type run struct {
	cfg     Config
	cl      *kgo.Client
	logger  *slog.Logger
	counter metric.Int64Counter
	sum     *Summary
	// next is the next offset to handle on each partition not finished yet.
	next map[int32]int64
	// warnedViews is set once the run has warned that it writes to viewsTopic.
	warnedViews bool
}

func (r *run) replay(ctx context.Context, spans map[int32]span) error {
	assign := map[int32]kgo.Offset{}
	for p, s := range spans {
		if s.start < s.end {
			assign[p] = kgo.NewOffset().At(s.start)
			r.next[p] = s.start
		}
	}
	if len(assign) == 0 {
		return nil
	}
	cons, err := kafkax.NewClient(r.cfg.Brokers, r.cfg.ClientID,
		kgo.ConsumePartitions(map[string]map[int32]kgo.Offset{r.cfg.From: assign}))
	if err != nil {
		return err
	}
	defer cons.Close()

	for len(r.next) > 0 {
		fetches := cons.PollFetches(ctx)
		if err := ctx.Err(); err != nil {
			return err
		}
		if errs := fetches.Errors(); len(errs) > 0 {
			return fmt.Errorf("fetch %s/%d: %w", errs[0].Topic, errs[0].Partition, errs[0].Err)
		}
		for _, rec := range fetches.Records() {
			next, pending := r.next[rec.Partition]
			if !pending || rec.Offset < next {
				continue
			}
			end := spans[rec.Partition].end
			if rec.Offset < end {
				if err := r.handle(ctx, rec); err != nil {
					return err
				}
			}
			if rec.Offset+1 >= end {
				delete(r.next, rec.Partition)
			} else {
				r.next[rec.Partition] = rec.Offset + 1
			}
		}
	}
	return nil
}

// handle filters, copies and produces one record of From.
func (r *run) handle(ctx context.Context, rec *kgo.Record) error {
	to, reason := r.cfg.To, ""
	group, _ := header(rec, kafkax.HeaderDLQGroup)
	switch {
	case r.cfg.Group != "" && group != r.cfg.Group:
		reason = "group"
	case to == "":
		if to, _ = header(rec, kafkax.HeaderDLQTopic); to == "" {
			reason = "no-destination"
		}
	}
	result := ResultReplayed
	switch {
	case reason != "":
		result = ResultSkipped
	case r.cfg.DryRun:
		result = ResultDryRun
	}

	names := make([]string, 0, len(rec.Headers))
	for _, h := range rec.Headers {
		names = append(names, h.Key)
	}
	attrs := []slog.Attr{slog.Int("partition", int(rec.Partition)), slog.Int64("offset", rec.Offset),
		slog.String("to", to), slog.Int("key_bytes", len(rec.Key)), slog.Any("headers", names)}
	if reason != "" {
		attrs = append(attrs, slog.String("reason", reason))
	}

	if to == viewsTopic && result != ResultSkipped && !r.warnedViews {
		r.warnedViews = true
		r.logger.LogAttrs(ctx, slog.LevelWarn, "dlq replay counts views again",
			slog.String("to", to), slog.String("rule", "replay each range of this topic once"))
	}

	switch result {
	case ResultReplayed:
		if err := r.produce(ctx, rec, to); err != nil {
			r.logger.LogAttrs(ctx, slog.LevelError, "dlq record", append(attrs, slog.String("result", "failed"))...)
			return fmt.Errorf("produce %s/%d@%d to %s: %w", rec.Topic, rec.Partition, rec.Offset, to, err)
		}
		r.sum.Replayed++
		r.sum.LastReplayed[rec.Partition] = rec.Offset
	case ResultSkipped:
		r.sum.Skipped++
	default:
		r.sum.DryRun++
	}
	r.counter.Add(ctx, 1, metric.WithAttributes(attribute.String("from", r.cfg.From),
		attribute.String("to", to), attribute.String("result", result)))
	r.logger.LogAttrs(ctx, slog.LevelInfo, "dlq record", append(attrs, slog.String("result", result))...)
	return nil
}

func (r *run) produce(ctx context.Context, rec *kgo.Record, to string) error {
	headers := make([]kgo.RecordHeader, 0, len(rec.Headers))
	for _, h := range rec.Headers {
		if !strings.HasPrefix(h.Key, "dlq-") {
			headers = append(headers, h)
		}
	}
	// Produced with ProduceSync rather than kafkax.Produce, which would replace the trace headers.
	out := &kgo.Record{Topic: to, Key: rec.Key, Value: rec.Value, Headers: headers}
	pctx, cancel := context.WithTimeout(ctx, produceTimeout)
	defer cancel()
	return r.cl.ProduceSync(pctx, out).FirstErr()
}

// ranges returns the offset range of every partition cfg reads.
func ranges(ctx context.Context, cl *kgo.Client, cfg Config) (map[int32]span, error) {
	parts, err := partitions(ctx, cl, cfg.From)
	if err != nil {
		return nil, err
	}
	if cfg.Partition != Unset {
		found := false
		for _, p := range parts {
			found = found || p == cfg.Partition
		}
		if !found {
			return nil, fmt.Errorf("topic %s has no partition %d", cfg.From, cfg.Partition)
		}
		parts = []int32{cfg.Partition}
	}
	first, err := listOffsets(ctx, cl, cfg.From, parts, -2)
	if err != nil {
		return nil, err
	}
	high, err := listOffsets(ctx, cl, cfg.From, parts, -1)
	if err != nil {
		return nil, err
	}
	since, until := map[int32]int64{}, map[int32]int64{}
	if !cfg.Since.IsZero() {
		if since, err = listOffsets(ctx, cl, cfg.From, parts, cfg.Since.UnixMilli()); err != nil {
			return nil, err
		}
	}
	if !cfg.Until.IsZero() {
		if until, err = listOffsets(ctx, cl, cfg.From, parts, cfg.Until.UnixMilli()); err != nil {
			return nil, err
		}
	}
	out := make(map[int32]span, len(parts))
	for _, p := range parts {
		s := span{start: first[p], end: high[p]}
		if cfg.StartOffset != Unset {
			s.start = max(s.start, cfg.StartOffset)
		}
		if cfg.EndOffset != Unset {
			s.end = min(s.end, cfg.EndOffset)
		}
		// The broker answers -1 when no record is at or after the time: the range ends there.
		if o, ok := since[p]; ok {
			s.start = max(s.start, endIfNone(o, high[p]))
		}
		if o, ok := until[p]; ok {
			s.end = min(s.end, endIfNone(o, high[p]))
		}
		out[p] = s
	}
	return out, nil
}

func endIfNone(offset, high int64) int64 {
	if offset < 0 {
		return high
	}
	return offset
}

// partitions returns the partition ids of topic.
func partitions(ctx context.Context, cl *kgo.Client, topic string) ([]int32, error) {
	req := kmsg.NewPtrMetadataRequest()
	t := kmsg.NewMetadataRequestTopic()
	t.Topic = kmsg.StringPtr(topic)
	req.Topics = append(req.Topics, t)
	resp, err := req.RequestWith(ctx, cl)
	if err != nil {
		return nil, fmt.Errorf("metadata of %s: %w", topic, err)
	}
	if len(resp.Topics) != 1 {
		return nil, fmt.Errorf("metadata of %s: %d topics in the response, want 1", topic, len(resp.Topics))
	}
	rt := resp.Topics[0]
	if err := kerr.ErrorForCode(rt.ErrorCode); err != nil {
		return nil, fmt.Errorf("metadata of %s: %w", topic, err)
	}
	out := make([]int32, 0, len(rt.Partitions))
	for _, p := range rt.Partitions {
		out = append(out, p.Partition)
	}
	return out, nil
}

// listOffsets returns, per partition of topic, the offset ListOffsets gives for timestamp: -2 the
// first offset on the log, -1 the high watermark, otherwise the first offset whose timestamp is
// at or after that many milliseconds since the epoch, or -1 when there is none.
func listOffsets(ctx context.Context, cl *kgo.Client, topic string, parts []int32, timestamp int64) (map[int32]int64, error) {
	req := kmsg.NewPtrListOffsetsRequest()
	t := kmsg.NewListOffsetsRequestTopic()
	t.Topic = topic
	for _, p := range parts {
		rp := kmsg.NewListOffsetsRequestTopicPartition()
		rp.Partition = p
		rp.Timestamp = timestamp
		t.Partitions = append(t.Partitions, rp)
	}
	req.Topics = append(req.Topics, t)
	resp, err := req.RequestWith(ctx, cl)
	if err != nil {
		return nil, fmt.Errorf("list offsets of %s: %w", topic, err)
	}
	out := make(map[int32]int64, len(parts))
	for _, rt := range resp.Topics {
		for _, rp := range rt.Partitions {
			if err := kerr.ErrorForCode(rp.ErrorCode); err != nil {
				return nil, fmt.Errorf("list offsets of %s/%d: %w", topic, rp.Partition, err)
			}
			out[rp.Partition] = rp.Offset
		}
	}
	for _, p := range parts {
		if _, ok := out[p]; !ok {
			return nil, fmt.Errorf("list offsets of %s/%d: partition missing from the response", topic, p)
		}
	}
	return out, nil
}

func header(r *kgo.Record, key string) (string, bool) {
	for _, h := range r.Headers {
		if h.Key == key {
			return string(h.Value), true
		}
	}
	return "", false
}

// offsets formats per-partition offsets as "0@41,2@7", in partition order.
func offsets(m map[int32]int64) string {
	parts := make([]string, 0, len(m))
	for _, p := range slices.Sorted(maps.Keys(m)) {
		parts = append(parts, strconv.Itoa(int(p))+"@"+strconv.FormatInt(m[p], 10))
	}
	return strings.Join(parts, ",")
}
