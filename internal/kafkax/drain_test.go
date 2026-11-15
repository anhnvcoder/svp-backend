package kafkax

// Stopping a consumer with a drain time: the record in progress keeps a live context until it
// is settled or the drain time has passed, and nothing else of the poll starts.

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
)

// inTopic is partition 0 of the one-partition topic "in".
var inTopic = TopicPartition{Topic: "in", Partition: 0}

// within waits for r to return, failing the test when it takes longer than limit.
func within(t *testing.T, r *running, limit time.Duration) error {
	t.Helper()
	select {
	case <-r.finished:
		return r.err
	case <-time.After(limit):
		t.Fatalf("Run did not return within %v", limit)
		return nil
	}
}

// A handler still running when the consumer stops finishes within the drain time on a live
// context: its record is committed and Run returns nil.
func TestDrainFinishesRecordInProgress(t *testing.T) {
	t.Parallel()
	brokers := cluster(t, 1, "in", "in.dlq")
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("job")})

	started, release := make(chan struct{}), make(chan struct{})
	ctxErr := make(chan error, 1)
	r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"}, DrainTimeout: 10 * time.Second,
		Handler: func(ctx context.Context, _ *kgo.Record, _ Attempt) error {
			close(started)
			select {
			case <-release:
			case <-ctx.Done():
			}
			ctxErr <- ctx.Err()
			return ctx.Err()
		}})
	waitFor(t, started, "the handler")
	r.cancel()
	time.Sleep(200 * time.Millisecond)
	close(release)

	if err := within(t, r, 5*time.Second); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}
	if err := <-ctxErr; err != nil {
		t.Errorf("handler context after the stop = %v, want live during the drain", err)
	}
	if got := committed(t, brokers, "g"); got[inTopic] != 1 {
		t.Errorf("committed offsets = %v, want the job committed", got)
	}
}

// A handler still running when the drain time passes sees its context canceled then, not at
// the stop: its record stays uncommitted and Run returns nil.
func TestDrainTimeoutCancelsRecordInProgress(t *testing.T) {
	t.Parallel()
	brokers := cluster(t, 1, "in", "in.dlq")
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("job")})

	const drain = 300 * time.Millisecond
	started := make(chan struct{})
	canceled := make(chan time.Time, 1)
	r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"}, DrainTimeout: drain,
		Handler: func(ctx context.Context, _ *kgo.Record, _ Attempt) error {
			close(started)
			<-ctx.Done()
			canceled <- time.Now()
			return ctx.Err()
		}})
	waitFor(t, started, "the handler")
	stopped := time.Now()
	r.cancel()

	if err := within(t, r, drain+5*time.Second); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}
	if after := (<-canceled).Sub(stopped); after < drain {
		t.Errorf("handler context canceled %v after the stop, want at least the drain time %v", after, drain)
	}
	if got := committed(t, brokers, "g"); len(got) != 0 {
		t.Errorf("committed offsets = %v, want none", got)
	}
	if next := nextInGroup(t, brokers, "g", "in"); string(next.Value) != "job" {
		t.Errorf("next record for the group = %q, want the interrupted job again", next.Value)
	}
}

// Records of the same poll after the one in progress do not start once the consumer stops:
// the first is committed, the second is left for the next member.
func TestDrainSkipsRecordsNotStarted(t *testing.T) {
	t.Parallel()
	brokers := cluster(t, 1, "in", "in.dlq")
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("first")}, &kgo.Record{Topic: "in", Value: []byte("second")})

	started, release := make(chan struct{}), make(chan struct{})
	var handled atomic.Int32
	r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"}, DrainTimeout: 10 * time.Second,
		Handler: func(ctx context.Context, rec *kgo.Record, _ Attempt) error {
			handled.Add(1)
			if string(rec.Value) == "first" {
				close(started)
				select {
				case <-release:
				case <-ctx.Done():
					return ctx.Err()
				}
			}
			return nil
		}})
	waitFor(t, started, "the handler")
	r.cancel()
	close(release)

	if err := within(t, r, 5*time.Second); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}
	if n := handled.Load(); n != 1 {
		t.Errorf("handler calls = %d, want 1: the second record must not start after the stop", n)
	}
	if got := committed(t, brokers, "g"); got[inTopic] != 1 {
		t.Errorf("committed offsets = %v, want the first record only", got)
	}
}

// With no drain time the record in progress is canceled at the stop, as before.
func TestNoDrainCancelsAtOnce(t *testing.T) {
	t.Parallel()
	brokers := cluster(t, 1, "in", "in.dlq")
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("job")})

	started := make(chan struct{})
	canceled := make(chan time.Time, 1)
	r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		Handler: func(ctx context.Context, _ *kgo.Record, _ Attempt) error {
			close(started)
			<-ctx.Done()
			canceled <- time.Now()
			return ctx.Err()
		}})
	waitFor(t, started, "the handler")
	stopped := time.Now()
	r.cancel()

	if err := within(t, r, 5*time.Second); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}
	if after := (<-canceled).Sub(stopped); after > time.Second {
		t.Errorf("handler context canceled %v after the stop, want at once", after)
	}
	if got := committed(t, brokers, "g"); len(got) != 0 {
		t.Errorf("committed offsets = %v, want none", got)
	}
}

// The backoff between two attempts runs on the drain context: a retry due within the drain time
// still runs and its success is committed; a backoff longer than the drain time ends with it,
// the record uncommitted.
func TestDrainBoundsBackoff(t *testing.T) {
	t.Parallel()
	tests := []struct {
		backoff, drain time.Duration
		wantAttempts   int32
		wantCommitted  bool
	}{
		{backoff: 200 * time.Millisecond, drain: 10 * time.Second, wantAttempts: 2, wantCommitted: true},
		{backoff: time.Hour, drain: 300 * time.Millisecond, wantAttempts: 1, wantCommitted: false},
	}
	for _, tt := range tests {
		t.Run(fmt.Sprintf("backoff %v drain %v", tt.backoff, tt.drain), func(t *testing.T) {
			t.Parallel()
			brokers := cluster(t, 1, "in", "in.dlq")
			produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("job")})

			failed := make(chan struct{})
			var attempts atomic.Int32
			r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"}, DrainTimeout: tt.drain,
				BackoffBase: tt.backoff, BackoffMax: tt.backoff,
				Handler: func(_ context.Context, _ *kgo.Record, a Attempt) error {
					attempts.Add(1)
					if a.Number == 1 {
						close(failed)
						return errors.New("transient")
					}
					return nil
				}})
			waitFor(t, failed, "the first attempt")
			r.cancel()

			if err := within(t, r, tt.drain+5*time.Second); err != nil {
				t.Fatalf("Run() = %v, want nil", err)
			}
			if n := attempts.Load(); n != tt.wantAttempts {
				t.Errorf("attempts = %d, want %d", n, tt.wantAttempts)
			}
			got := committed(t, brokers, "g")
			if tt.wantCommitted && got[inTopic] != 1 || !tt.wantCommitted && len(got) != 0 {
				t.Errorf("committed offsets = %v, want committed %v", got, tt.wantCommitted)
			}
		})
	}
}

// The drain time passes while the dead-letter produce waits for its ack: the source record stays
// uncommitted, as for a stop without a drain.
func TestDrainTimeoutDuringDeadLetterLeavesSourceUncommitted(t *testing.T) {
	c, brokers := fakeCluster(t, "in", "in.dlq")
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("bad")})
	held := holdProduce(c)

	const drain = 300 * time.Millisecond
	started, release := make(chan struct{}), make(chan struct{})
	r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"}, DrainTimeout: drain,
		Handler: func(context.Context, *kgo.Record, Attempt) error {
			close(started)
			<-release
			return Permanent(errors.New("bad event"))
		}})
	waitFor(t, started, "the handler")
	r.cancel()
	close(release)

	if err := within(t, r, drain+5*time.Second); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}
	select {
	case <-held:
	default:
		t.Fatal("the dead-letter produce never reached the broker")
	}
	if got := committed(t, brokers, "g"); len(got) != 0 {
		t.Errorf("committed offsets = %v, want none", got)
	}
}

func TestDrainContext(t *testing.T) {
	t.Parallel()
	t.Run("zero is the parent", func(t *testing.T) {
		t.Parallel()
		parent, cancel := context.WithCancel(t.Context())
		defer cancel()
		wctx, stop := drainContext(parent, 0)
		defer stop()
		if wctx != parent {
			t.Error("drainContext(ctx, 0) did not return ctx")
		}
	})
	t.Run("canceled the drain time after the parent", func(t *testing.T) {
		t.Parallel()
		parent, cancel := context.WithCancel(t.Context())
		const d = 100 * time.Millisecond
		wctx, stop := drainContext(parent, d)
		defer stop()
		cancel()
		if wctx.Err() != nil {
			t.Fatal("drain context canceled with its parent")
		}
		select {
		case <-wctx.Done():
		case <-time.After(5 * time.Second):
			t.Fatal("drain context not canceled after the drain time")
		}
	})
	t.Run("stop cancels it", func(t *testing.T) {
		t.Parallel()
		wctx, stop := drainContext(t.Context(), time.Hour)
		stop()
		if wctx.Err() == nil {
			t.Error("drain context live after stop")
		}
	})
}
