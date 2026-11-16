package outbox

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"slices"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/metric/noop"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"

	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/telemetry"
)

// lockID is the transaction-scoped advisory lock a relay holds while it sends a batch, so only
// one relay per database sends at a time. Advisory locks are per database and each service has
// its own database, so one constant serves every service. The bytes spell "svpoutbx".
const lockID int64 = 0x7376706f75746278

// Defaults of a Relay; tests shorten them.
const (
	batchSize        = 100
	idleWait         = 200 * time.Millisecond
	produceTimeout   = 10 * time.Second
	postgresTimeout  = 5 * time.Second
	cleanupTimeout   = 30 * time.Second
	retryBase        = 500 * time.Millisecond
	retryMax         = 10 * time.Second
	cleanupEvery     = 10 * time.Minute
	cleanupBatchSize = 1000
	lastErrorMax     = 512
)

// permanentErrors are the produce errors that a record causes itself and that sending it again
// cannot fix, so the relay marks the row failed instead of retrying the whole batch. They are the
// codes of pkg/kerr/kerr.go in franz-go v1.22.2 whose retriable flag is false and whose cause is
// the record:
//
//   - MESSAGE_TOO_LARGE (10): the record is over the size the broker or the client accepts. The
//     client fails such a record before sending it with an error that wraps kerr.MessageTooLarge
//     (pkg/kgo/producer.go and pkg/kgo/sink.go), so errors.Is matches both.
//   - INVALID_RECORD (87): the broker's validation rejected the record.
//
// Every other code is retried with the whole batch: CORRUPT_MESSAGE is retriable, and the other
// codes the file marks not retriable come from the topic, the client's settings, the credentials
// or the broker (TOPIC_AUTHORIZATION_FAILED, RECORD_LIST_TOO_LARGE of a whole batch,
// INVALID_TIMESTAMP of a skewed clock, as the client stamps each record when it sends it), and
// fixing those makes the same rows go through.
var permanentErrors = []error{kerr.MessageTooLarge, kerr.InvalidRecord}

// permanent reports whether err is one of permanentErrors.
func permanent(err error) bool {
	for _, p := range permanentErrors {
		if errors.Is(err, p) {
			return true
		}
	}
	return false
}

// Relay sends the unsent outbox rows of one database to Kafka, oldest id first.
type Relay struct {
	pool   *pgxpool.Pool
	client *kgo.Client
	logger *slog.Logger

	idleWait        time.Duration
	produceTimeout  time.Duration
	postgresTimeout time.Duration
	cleanupTimeout  time.Duration
	retryBase       time.Duration
	retryMax        time.Duration
	cleanupEvery    time.Duration
	relayLoop       *telemetry.Loop
	cleanupLoop     *telemetry.Loop
	rowsFailed      metric.Int64Counter
}

// NewRelay returns a relay reading the outbox table through pool and producing with client.
func NewRelay(pool *pgxpool.Pool, client *kgo.Client, logger *slog.Logger) *Relay {
	rowsFailed, err := otel.Meter("github.com/anhnvcoder/svp-backend/internal/outbox").Int64Counter("svp.outbox.rows.failed")
	if err != nil {
		otel.Handle(err)
		rowsFailed = noop.Int64Counter{}
	}
	return &Relay{
		pool:            pool,
		client:          client,
		logger:          logger,
		idleWait:        idleWait,
		produceTimeout:  produceTimeout,
		postgresTimeout: postgresTimeout,
		cleanupTimeout:  cleanupTimeout,
		retryBase:       retryBase,
		retryMax:        retryMax,
		cleanupEvery:    cleanupEvery,
		relayLoop:       telemetry.NewLoop("outbox-relay"),
		cleanupLoop:     telemetry.NewLoop("outbox-cleanup"),
		rowsFailed:      rowsFailed,
	}
}

// Run sends batches until ctx is canceled. A full batch is followed at once by the next one, a
// partial or empty batch by a short wait; a failed batch is rolled back and retried with a
// growing, randomized wait. A row that fails with a permanent error (permanentErrors) is marked
// failed and never read again, and the rows after it go on, so a later event of the same key can
// reach Kafka while an earlier one did not. Run also deletes rows sent more than 24 hours ago, at
// start and then every 10 minutes; failed rows stay.
func (r *Relay) Run(ctx context.Context) {
	r.cleanup(ctx)
	cleanup := time.NewTicker(r.cleanupEvery)
	defer cleanup.Stop()
	next := time.NewTimer(0)
	defer next.Stop()
	failures := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-cleanup.C:
			r.cleanup(ctx)
		case <-next.C:
			n, err := r.sendBatch(ctx)
			if err == nil {
				r.relayLoop.Succeeded()
			}
			switch {
			case ctx.Err() != nil:
				return
			case err != nil:
				wait := r.retryWait(failures)
				failures++
				r.logger.LogAttrs(ctx, slog.LevelWarn, "outbox relay failed, retrying",
					slog.Duration("backoff", wait), slog.String("error", err.Error()))
				next.Reset(wait)
			case n == batchSize:
				failures = 0
				next.Reset(0)
			default:
				failures = 0
				next.Reset(r.idleWait)
			}
		}
	}
}

// retryWait returns the wait after failures earlier consecutive failures: retryBase doubled
// for each, capped at retryMax, then randomized to between half and all of it so the relays of
// several replicas do not retry in step.
func (r *Relay) retryWait(failures int) time.Duration {
	d := r.retryBase
	for range failures {
		if d >= r.retryMax {
			break
		}
		d *= 2
	}
	d = min(d, r.retryMax)
	return d/2 + rand.N(d/2+1) //nolint:gosec // jitter, not a secret
}

type row struct {
	id        int64
	topic     string
	key       string
	payload   []byte
	headers   map[string]string
	createdAt time.Time
}

// failedRow is a row the relay gives up on, with the Kafka error that stopped it.
type failedRow struct {
	id    int64
	topic string
	err   string
}

// sendBatch sends up to batchSize unsent rows in one transaction holding lockID, marks the rows
// sent and the rows that failed with a permanent error failed, and commits. It returns the number
// of rows it settled either way, 0 when another relay holds the lock. On any other error the
// transaction rolls back and the rows stay unsent, including rows already produced.
func (r *Relay) sendBatch(ctx context.Context) (n int, err error) {
	rctx, readCancel := context.WithTimeout(ctx, r.postgresTimeout)
	defer readCancel()
	tx, err := r.pool.Begin(rctx)
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	// After Commit this is a no-op; on ctx cancellation it still reaches the server.
	defer func() {
		rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), r.postgresTimeout)
		defer cancel()
		if rollbackErr := tx.Rollback(rctx); rollbackErr != nil && !errors.Is(rollbackErr, pgx.ErrTxClosed) {
			err = errors.Join(err, fmt.Errorf("rollback outbox batch: %w", rollbackErr))
		}
	}()

	var locked bool
	if err := tx.QueryRow(rctx, "SELECT pg_try_advisory_xact_lock($1)", lockID).Scan(&locked); err != nil {
		return 0, fmt.Errorf("take relay lock: %w", err)
	}
	if !locked {
		return 0, nil
	}

	rows, err := readUnsent(rctx, tx)
	readCancel()
	if err != nil {
		return 0, err
	}
	if len(rows) == 0 {
		return 0, nil
	}

	pctx, cancel := context.WithTimeout(ctx, r.produceTimeout)
	sentIDs, failed, err := r.produce(pctx, rows)
	cancel()
	if err != nil {
		return 0, fmt.Errorf("send outbox rows %d..%d: %w", rows[0].id, rows[len(rows)-1].id, err)
	}
	sentAt := time.Now()

	mctx, markCancel := context.WithTimeout(ctx, r.postgresTimeout)
	defer markCancel()
	if _, err := tx.Exec(mctx, "UPDATE outbox SET published_at = now() WHERE id = ANY($1)", sentIDs); err != nil {
		return 0, fmt.Errorf("mark outbox rows sent: %w", err)
	}
	if len(failed) > 0 {
		failedIDs := make([]int64, len(failed))
		errs := make([]string, len(failed))
		for i, f := range failed {
			failedIDs[i], errs[i] = f.id, f.err
		}
		if _, err := tx.Exec(mctx, `UPDATE outbox AS o SET failed_at = now(), last_error = f.err
			  FROM unnest($1::bigint[], $2::text[]) AS f(id, err) WHERE o.id = f.id`, failedIDs, errs); err != nil {
			return 0, fmt.Errorf("mark outbox rows failed: %w", err)
		}
	}
	if err := tx.Commit(mctx); err != nil {
		return 0, fmt.Errorf("commit outbox rows sent: %w", err)
	}
	for _, f := range failed {
		r.rowsFailed.Add(ctx, 1, metric.WithAttributes(attribute.String("topic", f.topic)))
		r.logger.LogAttrs(ctx, slog.LevelError, "outbox row failed permanently, skipped",
			slog.Int64("id", f.id), slog.String("topic", f.topic), slog.String("error", f.err))
	}
	r.logger.LogAttrs(ctx, slog.LevelInfo, "outbox batch sent",
		slog.Int("rows", len(rows)),
		slog.Int("failed", len(failed)),
		slog.Int64("first_id", rows[0].id),
		slog.Int64("last_id", rows[len(rows)-1].id),
		slog.Duration("max_lag", sentAt.Sub(rows[0].createdAt)))
	return len(rows), nil
}

// produce sends rows and returns the ids sent and the rows that failed with a permanent error.
// The client fails every record of a partition's batch with the broker's error, so a permanent
// error of the batch does not tell which records caused it: produce then sends each row again on
// its own, in id order, and a row fails only when it fails alone. Rows the batch had already
// written are written again, as after any failed batch. Any other error, of the batch or of a row
// sent alone, is returned and nothing is marked.
func (r *Relay) produce(ctx context.Context, rows []row) (sentIDs []int64, failed []failedRow, err error) {
	records := make([]*kgo.Record, len(rows))
	for i, x := range rows {
		records[i] = toRecord(ctx, x)
	}
	err = kafkax.Produce(ctx, r.client, records...)
	if err == nil {
		for _, x := range rows {
			sentIDs = append(sentIDs, x.id)
		}
		return sentIDs, nil, nil
	}
	if !permanent(err) {
		return nil, nil, err
	}
	for _, x := range rows {
		err := kafkax.Produce(ctx, r.client, toRecord(ctx, x))
		switch {
		case err == nil:
			sentIDs = append(sentIDs, x.id)
		case permanent(err):
			failed = append(failed, failedRow{id: x.id, topic: x.topic, err: truncate(err.Error(), lastErrorMax)})
		default:
			return nil, nil, fmt.Errorf("row %d alone: %w", x.id, err)
		}
	}
	return sentIDs, failed, nil
}

// truncate returns s cut to at most n characters, on a character boundary.
func truncate(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

func readUnsent(ctx context.Context, tx pgx.Tx) ([]row, error) {
	rs, err := tx.Query(ctx,
		`SELECT id, topic, record_key, payload, headers, created_at
		   FROM outbox WHERE published_at IS NULL AND failed_at IS NULL ORDER BY id LIMIT $1`, batchSize)
	if err != nil {
		return nil, fmt.Errorf("read outbox: %w", err)
	}
	out, err := pgx.CollectRows(rs, func(rs pgx.CollectableRow) (row, error) {
		var x row
		err := rs.Scan(&x.id, &x.topic, &x.key, &x.payload, &x.headers, &x.createdAt)
		return x, err
	})
	if err != nil {
		return nil, fmt.Errorf("read outbox: %w", err)
	}
	return out, nil
}

func toRecord(ctx context.Context, x row) *kgo.Record {
	parent := trace.ContextWithSpanContext(ctx, trace.SpanContext{})
	parent = otel.GetTextMapPropagator().Extract(parent, propagation.MapCarrier(x.headers))
	rec := &kgo.Record{Topic: x.topic, Key: []byte(x.key), Value: x.payload, Context: parent}
	keys := make([]string, 0, len(x.headers))
	for k := range x.headers {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	for _, k := range keys {
		if k == "traceparent" || k == "tracestate" {
			continue
		}
		rec.Headers = append(rec.Headers, kgo.RecordHeader{Key: k, Value: []byte(x.headers[k])})
	}
	return rec
}

// cleanup deletes rows sent more than 24 hours ago, cleanupBatchSize rows per statement so no
// statement holds many row locks for long. Unsent rows are never deleted. Deleting is
// idempotent, so relays of several replicas may run it at the same time without the lock.
func (r *Relay) cleanup(ctx context.Context) {
	cctx, cancel := context.WithTimeout(ctx, r.cleanupTimeout)
	defer cancel()
	total := int64(0)
	for {
		tag, err := r.pool.Exec(cctx,
			`DELETE FROM outbox WHERE id IN (
			   SELECT id FROM outbox WHERE published_at < now() - interval '24 hours' LIMIT $1)`,
			cleanupBatchSize)
		if err != nil {
			if ctx.Err() == nil {
				r.logger.LogAttrs(ctx, slog.LevelWarn, "outbox cleanup failed",
					slog.Int64("deleted", total), slog.String("error", err.Error()))
			}
			return
		}
		r.cleanupLoop.Succeeded()
		total += tag.RowsAffected()
		if tag.RowsAffected() < cleanupBatchSize {
			break
		}
	}
	if total > 0 {
		r.logger.LogAttrs(ctx, slog.LevelInfo, "outbox cleanup done", slog.Int64("deleted", total))
	}
}
