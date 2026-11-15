package outbox

import (
	"bytes"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/kmsg"
	"go.opentelemetry.io/otel/attribute"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"

	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
)

// invalidMarker is a header key the tests put on a row for the fake broker to reject it.
const invalidMarker = "test-invalid-record"

// faultCluster is cluster that also returns the fake broker, to install faults on it.
func faultCluster(t *testing.T) (*kfake.Cluster, string) {
	t.Helper()
	c, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(1, topic))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return c, strings.Join(c.ListenAddrs(), ",")
}

// carries reports whether a produce request holds a record with marker, which the uncompressed
// record bytes show as is.
func carries(marker string) func(kmsg.Request) bool {
	return func(req kmsg.Request) bool {
		pr, ok := req.(*kmsg.ProduceRequest)
		if !ok {
			return false
		}
		for _, t := range pr.Topics {
			for _, p := range t.Partitions {
				if bytes.Contains(p.Records, []byte(marker)) {
					return true
				}
			}
		}
		return false
	}
}

// writeLarge commits an event for key over the client's largest record batch and returns its
// event_id. Its payload is a run of 'x', which last_error must never show.
func writeLarge(t *testing.T, pool *pgxpool.Pool, key string) string {
	t.Helper()
	tx, err := pool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(t.Context()) }()
	ev := &videov1.VideoEvent{
		Meta:  NewMeta(),
		Event: &videov1.VideoEvent_VideoUploaded{VideoUploaded: &videov1.VideoUploaded{VideoId: strings.Repeat("x", 1_100_000)}},
	}
	if err := Write(t.Context(), tx, topic, key, ev); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(t.Context()); err != nil {
		t.Fatal(err)
	}
	return ev.GetMeta().GetEventId()
}

// writeInvalid commits an event for key that the broker of carries(invalidMarker) rejects.
func writeInvalid(t *testing.T, pool *pgxpool.Pool, key string) string {
	t.Helper()
	id := write(t.Context(), t, pool, key)
	if _, err := pool.Exec(t.Context(), "UPDATE outbox SET headers = jsonb_build_object($1::text, 'yes') WHERE event_id = $2",
		invalidMarker, id); err != nil {
		t.Fatal(err)
	}
	return id
}

type failedState struct {
	failedAt  *time.Time
	lastError *string
}

func rowState(t *testing.T, pool *pgxpool.Pool, eventID string) failedState {
	t.Helper()
	var s failedState
	if err := pool.QueryRow(t.Context(), "SELECT failed_at, last_error FROM outbox WHERE event_id = $1", eventID).
		Scan(&s.failedAt, &s.lastError); err != nil {
		t.Fatal(err)
	}
	return s
}

func countFailed(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(t.Context(), "SELECT count(*) FROM outbox WHERE failed_at IS NOT NULL").Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// failedCounts returns svp.outbox.rows.failed by topic.
func failedCounts(t *testing.T, reader *sdkmetric.ManualReader) map[string]int64 {
	t.Helper()
	var data metricdata.ResourceMetrics
	if err := reader.Collect(t.Context(), &data); err != nil {
		t.Fatal(err)
	}
	out := map[string]int64{}
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			if m.Name != "svp.outbox.rows.failed" {
				continue
			}
			for _, p := range m.Data.(metricdata.Sum[int64]).DataPoints {
				v, _ := p.Attributes.Value(attribute.Key("topic"))
				out[v.AsString()] += p.Value
			}
		}
	}
	return out
}

// distinct returns ids without repeats, in the order each first appears.
func distinct(ids []string) []string {
	var out []string
	for _, id := range ids {
		if !slices.Contains(out, id) {
			out = append(out, id)
		}
	}
	return out
}

func checkFailed(t *testing.T, pool *pgxpool.Pool, eventID, code string) failedState {
	t.Helper()
	s := rowState(t, pool, eventID)
	if s.failedAt == nil || s.lastError == nil {
		t.Fatalf("row %s: failed_at %v, last_error %v; want both set", eventID, s.failedAt, s.lastError)
	}
	if !strings.Contains(*s.lastError, code) || strings.Contains(*s.lastError, "xxxx") ||
		len([]rune(*s.lastError)) > lastErrorMax {
		t.Errorf("last_error = %q, want the Kafka error %s, no payload, at most %d characters", *s.lastError, code, lastErrorMax)
	}
	return s
}

func TestRelayMarksTooLargeRowAndSendsTheRest(t *testing.T) {
	_, reader := traceTelemetry(t)
	pool := newDB(t, "toolarge")
	brokers := cluster(t, 1)
	key, other := ids.New(), ids.New()
	before := write(t.Context(), t, pool, key)
	large := writeLarge(t, pool, key)
	after := write(t.Context(), t, pool, key)
	otherKey := write(t.Context(), t, pool, other)

	r, logs := newRelay(pool, newClient(t, brokers))
	start(t, r)
	eventually(t, "the large row to be marked failed", func() bool { return countFailed(t, pool) == 1 })
	state := checkFailed(t, pool, large, "MESSAGE_TOO_LARGE")

	// Rows the batch had sent before the large one failed are sent again alone: duplicates, in order.
	got := distinct(eventIDs(t, consume(t, brokers, 3, 300*time.Millisecond)))
	if strings.Join(got, ",") != strings.Join([]string{before, after, otherKey}, ",") {
		t.Errorf("sent %v, want %v without the large row", got, []string{before, after, otherKey})
	}
	if n := countUnsent(t, pool); n != 1 {
		t.Errorf("%d rows unsent, want only the failed one", n)
	}

	// Later batches neither read the failed row again nor count it twice.
	next := write(t.Context(), t, pool, key)
	eventually(t, "the next row to be sent", func() bool { return countUnsent(t, pool) == 1 })
	if s := rowState(t, pool, large); s.failedAt == nil || !s.failedAt.Equal(*state.failedAt) {
		t.Errorf("failed_at changed from %v to %v", state.failedAt, s.failedAt)
	}
	if got := distinct(eventIDs(t, consume(t, brokers, 4, 300*time.Millisecond))); got[len(got)-1] != next {
		t.Errorf("last sent %v, want the next row %s", got, next)
	}
	if n := len(logs.records(t, "outbox row failed permanently, skipped")); n != 1 {
		t.Errorf("logged %d failed rows, want 1", n)
	}
	if got := failedCounts(t, reader); len(got) != 1 || got[topic] != 1 {
		t.Errorf("svp.outbox.rows.failed = %v, want 1 for %s", got, topic)
	}
}

func TestRelayBatchOfOnlyFailedRowsMarksThemAll(t *testing.T) {
	_, reader := traceTelemetry(t)
	pool := newDB(t, "allfailed")
	key := ids.New()
	for range 3 {
		writeLarge(t, pool, key)
	}

	r, logs := newRelay(pool, newClient(t, cluster(t, 1)))
	start(t, r)
	eventually(t, "every row to be marked failed", func() bool { return countFailed(t, pool) == 3 })
	// Give a relay that read them again time to do so.
	time.Sleep(20 * r.idleWait)
	if n := len(logs.records(t, "outbox row failed permanently, skipped")); n != 3 {
		t.Errorf("logged %d failed rows, want 3", n)
	}
	if n := len(logs.records(t, "outbox relay failed, retrying")); n != 0 {
		t.Errorf("relay retried %d times, want none", n)
	}
	if got := failedCounts(t, reader); got[topic] != 3 {
		t.Errorf("svp.outbox.rows.failed = %v, want 3 for %s", got, topic)
	}
}

// The broker rejects a whole partition batch for one invalid record, and the client fails every
// record in it: only the record that fails alone is marked.
func TestRelayMarksOnlyTheRecordTheBrokerRejects(t *testing.T) {
	_, reader := traceTelemetry(t)
	pool := newDB(t, "invalid")
	c, brokers := faultCluster(t)
	c.Fault(kfake.Fault{Keys: []kmsg.Key{kmsg.Produce}, Topic: topic, Err: kerr.InvalidRecord, Count: -1,
		When: carries(invalidMarker)})
	key := ids.New()
	before := write(t.Context(), t, pool, key)
	invalid := writeInvalid(t, pool, key)
	after := write(t.Context(), t, pool, key)

	r, _ := newRelay(pool, newClient(t, brokers, kgo.ProducerBatchCompression(kgo.NoCompression())))
	start(t, r)
	eventually(t, "the invalid row to be marked failed", func() bool { return countFailed(t, pool) == 1 })
	checkFailed(t, pool, invalid, "INVALID_RECORD")
	if got := eventIDs(t, consume(t, brokers, 2, 300*time.Millisecond)); strings.Join(got, ",") != before+","+after {
		t.Errorf("sent %v, want %v", got, []string{before, after})
	}
	if n := countUnsent(t, pool); n != 1 {
		t.Errorf("%d rows unsent, want only the failed one", n)
	}
	if got := failedCounts(t, reader); got[topic] != 1 {
		t.Errorf("svp.outbox.rows.failed = %v, want 1 for %s", got, topic)
	}
}

// Errors that are not the record's own roll the whole batch back and retry it, and mark nothing:
// a temporary one, the producer's missing permission, and CORRUPT_MESSAGE, which the codes list
// as retriable.
func TestRelayRetriesErrorsThatAreNotPermanent(t *testing.T) {
	for _, code := range []*kerr.Error{kerr.NotEnoughReplicas, kerr.TopicAuthorizationFailed, kerr.CorruptMessage} {
		t.Run(code.Message, func(t *testing.T) {
			_, reader := traceTelemetry(t)
			pool := newDB(t, "retry_"+strings.ToLower(code.Message))
			c, brokers := faultCluster(t)
			fault := c.Fault(kfake.Fault{Keys: []kmsg.Key{kmsg.Produce}, Topic: topic, Err: code, Count: -1})
			want := []string{write(t.Context(), t, pool, ids.New()), write(t.Context(), t, pool, ids.New())}

			r, logs := newRelay(pool, newClient(t, brokers))
			start(t, r)
			eventually(t, "two failed attempts", func() bool { return len(logs.records(t, "outbox relay failed, retrying")) >= 2 })
			if n := countUnsent(t, pool); n != 2 {
				t.Fatalf("%d rows unsent while the broker fails them, want 2", n)
			}
			if n := countFailed(t, pool); n != 0 {
				t.Fatalf("%d rows marked failed, want none", n)
			}

			fault.Remove()
			got := distinct(eventIDs(t, consume(t, brokers, 2, 300*time.Millisecond)))
			if strings.Join(got, ",") != strings.Join(want, ",") {
				t.Errorf("sent %v after the fault, want %v", got, want)
			}
			eventually(t, "the rows to be marked sent", func() bool { return countUnsent(t, pool) == 0 })
			if n := countFailed(t, pool); n != 0 {
				t.Errorf("%d rows marked failed, want none", n)
			}
			if got := failedCounts(t, reader); len(got) != 0 {
				t.Errorf("svp.outbox.rows.failed = %v, want no row counted", got)
			}
		})
	}
}

func TestPermanentErrors(t *testing.T) {
	t.Parallel()
	tests := []struct {
		err  error
		want bool
	}{
		{kerr.MessageTooLarge, true},
		{kerr.InvalidRecord, true},
		{kerr.CorruptMessage, false},
		{kerr.TopicAuthorizationFailed, false},
		{kerr.RecordListTooLarge, false},
		{kerr.InvalidTimestamp, false},
		{kerr.NotEnoughReplicas, false},
	}
	for _, tt := range tests {
		if got := permanent(tt.err); got != tt.want {
			t.Errorf("permanent(%v) = %v, want %v", tt.err, got, tt.want)
		}
	}
}

func TestTruncate(t *testing.T) {
	t.Parallel()
	if got := truncate("short", 512); got != "short" {
		t.Errorf("truncate(short) = %q", got)
	}
	long := strings.Repeat("é", 600)
	if got := truncate(long, 512); len([]rune(got)) != 512 || got != strings.Repeat("é", 512) {
		t.Errorf("truncate kept %d characters, want 512 whole ones", len([]rune(got)))
	}
}
