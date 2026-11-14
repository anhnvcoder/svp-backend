// Package mediaconvert transcodes with AWS Elemental MediaConvert instead of ffmpeg, under the
// same event contract as package worker: it consumes video.uploaded from video.lifecycle.v1 and
// publishes transcode.completed or transcode.failed to media.transcodes.v1. Two loops run in one
// process: the Kafka consumer, which checks the source with Probe and creates a job, and a loop
// over the SQS queue to which EventBridge sends the COMPLETE and ERROR state changes of jobs.
//
// Flow of a version (the event_id of its video.uploaded, as in package worker): Probe the source
// in the uploads bucket against the limits of package transcode; a source over them gets a
// record of its failure reason and no job. Otherwise CreateJob writes the HLS renditions and a
// frame capture flat into media/<video_id>/<version>/<attempt>/, attempt being a new UUID per
// call, and the job is recorded. When the job completes, every object of the attempt is copied
// in place with the Cache-Control and Content-Type that worker gives its objects, the frame
// capture becomes thumbnail.jpg, the master playlist is created once, and the result is read
// back from the stored playlists as worker reads it.
//
// Idempotency: the job record transcode-jobs/<video_id>/<version>.json in the media bucket is
// written only with If-None-Match, so the first record wins and is never replaced. The result
// of a version is that of the job (or failure reason) in its record; a job not named there, such
// as one whose CreateJob response was lost or one created by a consumer that lost its partition,
// never decides anything. Both loops end in the same settle step on the record, so a duplicate
// record, message or crash between publish and commit publishes the same result again: delivery
// is at-least-once, and every event of a version carries one result.
//
// Errors: a bad video.uploaded goes to the dead-letter topic; storage, MediaConvert and Kafka
// errors are retried, and on the last try the version is recorded as RETRIES_EXHAUSTED. When even
// that record cannot be written nothing is published and the record goes to the dead-letter
// topic: the video stays PROCESSING rather than failing while a job may still be running. An SQS
// message the bridge cannot vouch for (not a state change of a job of its queue, or a job whose
// metadata or destination is not its own) is left on the queue, and its redrive policy moves it
// to the dead-letter queue. A job that ends in ERROR is not submitted again.
//
// Design notes: docs/explanation/transcode.md.
package mediaconvert

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/mediaconvert"
	"github.com/aws/aws-sdk-go-v2/service/mediaconvert/types"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/trace"

	mediav1 "github.com/anhnvcoder/svp-backend/gen/go/svp/media/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/logx"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/worker"
)

const instrumentationName = "github.com/anhnvcoder/svp-backend/services/media-worker/internal/mediaconvert"

const (
	// tryTimeout bounds one try at a video.uploaded or one SQS message: Probe, CreateJob, and on a
	// completed job the in-place copy of its few dozen objects and the master. Past it the try
	// fails as temporary.
	tryTimeout = 2 * time.Minute
	// rebalanceTimeout covers the retry budget of a record, as in package worker.
	rebalanceTimeout = worker.MaxAttempts*(tryTimeout+worker.ProduceTimeout) + (worker.MaxAttempts-1)*worker.BackoffMax

	// receiveWait is the long polling wait of one ReceiveMessage, the most SQS allows.
	receiveWait = 20
	// receiveBatch is the most messages one ReceiveMessage returns.
	receiveBatch = 10
	// receiveRetry is the pause after a failed ReceiveMessage.
	receiveRetry = 5 * time.Second
)

// Client is the part of the MediaConvert API the bridge calls.
type Client interface {
	Probe(ctx context.Context, in *mediaconvert.ProbeInput, opts ...func(*mediaconvert.Options)) (*mediaconvert.ProbeOutput, error)
	CreateJob(ctx context.Context, in *mediaconvert.CreateJobInput, opts ...func(*mediaconvert.Options)) (*mediaconvert.CreateJobOutput, error)
	GetJob(ctx context.Context, in *mediaconvert.GetJobInput, opts ...func(*mediaconvert.Options)) (*mediaconvert.GetJobOutput, error)
}

// Queue is the part of the SQS API the bridge calls.
type Queue interface {
	ReceiveMessage(ctx context.Context, in *sqs.ReceiveMessageInput, opts ...func(*sqs.Options)) (*sqs.ReceiveMessageOutput, error)
	DeleteMessage(ctx context.Context, in *sqs.DeleteMessageInput, opts ...func(*sqs.Options)) (*sqs.DeleteMessageOutput, error)
}

// Storage is the part of objstore.Store the bridge uses. Errors follow objstore: ErrNotFound,
// ErrExists and ErrAccessDenied wrapped; anything else is temporary.
type Storage interface {
	Download(ctx context.Context, key, path string, maxBytes int64) error
	// Create writes key only when it holds no object yet, ErrExists otherwise.
	Create(ctx context.Context, key, path, contentType, cacheControl string) error
	// Exists lists key: false only when storage answered that it holds no such object.
	Exists(ctx context.Context, key string) (bool, error)
	List(ctx context.Context, prefix string) ([]string, error)
	// Copy copies src to dst replacing the metadata; src equal to dst rewrites it in place.
	Copy(ctx context.Context, src, dst, contentType, cacheControl string) error
}

// Config holds the resources of the environment the bridge works with.
type Config struct {
	// QueueARN is the MediaConvert queue jobs go to; RoleARN the role MediaConvert reads and
	// writes S3 with.
	QueueARN string
	RoleARN  string
	// EventsQueueURL is the SQS queue receiving the state changes of the jobs.
	EventsQueueURL string
	UploadsBucket  string
	MediaBucket    string
	// WorkDir holds the small files of a try (playlists, records), each try in a directory of its
	// own named by a UUID.
	WorkDir string
}

// Bridge runs both loops.
type Bridge struct {
	cfg      Config
	mc       Client
	events   Queue
	store    Storage
	producer *kgo.Client
	logger   *slog.Logger
	// newID returns the attempt of a new job; tests make it deterministic.
	newID func() string
	// tryTimeout and receiveRetry are the constants of the same names; tests shorten them.
	tryTimeout   time.Duration
	receiveRetry time.Duration
	// transcodeDuration is svp.transcode.duration, recorded from the job's timing.
	transcodeDuration metric.Float64Histogram
}

// New returns a Bridge calling mc, reading state changes from events, keeping objects in store
// and publishing with producer. Its spans and metrics go to the global providers.
func New(cfg Config, mc Client, events Queue, store Storage, producer *kgo.Client, logger *slog.Logger) *Bridge {
	return &Bridge{
		cfg: cfg, mc: mc, events: events, store: store, producer: producer, logger: logger,
		newID: ids.New, tryTimeout: tryTimeout, receiveRetry: receiveRetry,
		transcodeDuration: worker.TranscodeDuration(),
	}
}

// ConsumerConfig returns the consumer of worker.InputTopic in worker.Group with the retry budget
// of package worker.
func (b *Bridge) ConsumerConfig(brokers string) kafkax.ConsumerConfig {
	return kafkax.ConsumerConfig{
		Brokers:          brokers,
		ClientID:         worker.Group,
		Group:            worker.Group,
		Topics:           []string{worker.InputTopic},
		Handler:          b.Handle,
		Logger:           b.logger,
		MaxAttempts:      worker.MaxAttempts,
		BackoffBase:      worker.BackoffBase,
		BackoffMax:       worker.BackoffMax,
		MaxPollRecords:   1,
		BlockRebalance:   true,
		RebalanceTimeout: rebalanceTimeout,
	}
}

// Handle is the kafkax.Handler of worker.InputTopic.
func (b *Bridge) Handle(ctx context.Context, r *kgo.Record, a kafkax.Attempt) error {
	up, version, err := worker.Decode(r)
	if err != nil || up == nil {
		return err
	}
	id := up.GetVideoId()
	ctx = logx.With(ctx, slog.String("video_id", id), slog.String("version", version))

	res, err := b.try(ctx, id, func(ctx context.Context, dir string) (settled, error) {
		return b.uploaded(ctx, dir, id, version)
	})
	if err != nil {
		if ctx.Err() != nil || !a.Last {
			b.logger.LogAttrs(ctx, slog.LevelWarn, "transcode job interrupted", slog.Int("attempt", a.Number),
				slog.String("error", b.scrub(err)))
			return err
		}
		cause := err
		res, err = b.try(ctx, id, func(ctx context.Context, dir string) (settled, error) {
			return b.giveUp(ctx, dir, id, version, cause)
		})
		if err != nil {
			// The record of the version is unknown: no result is published while a job may run.
			b.logger.LogAttrs(ctx, slog.LevelError, "transcode result undecided", slog.String("error", b.scrub(err)))
			return err
		}
	}
	return b.finish(ctx, id, res, "")
}

// try runs fn under tryTimeout with a work directory of its own, removed on return.
func (b *Bridge) try(ctx context.Context, id string, fn func(ctx context.Context, dir string) (settled, error)) (settled, error) {
	dir := filepath.Join(b.cfg.WorkDir, ids.New())
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return settled{}, fmt.Errorf("create job directory: %w", err)
	}
	defer func() { _ = os.RemoveAll(dir) }()
	ctx, cancel := context.WithTimeout(ctx, b.tryTimeout)
	defer cancel()
	ctx, span := otel.Tracer(instrumentationName).Start(ctx, "settle",
		trace.WithAttributes(attribute.String("video_id", id)))
	defer span.End()
	res, err := fn(ctx, dir)
	if err != nil {
		span.SetStatus(codes.Error, "settle failed")
	}
	return res, err
}

// finish publishes the result of a settle, if any, and records the failed sample of
// svp.transcode.duration it carries. messageJob is the job of the SQS message handled, empty for
// a video.uploaded.
func (b *Bridge) finish(ctx context.Context, id string, res settled, messageJob string) error {
	if res.ev == nil {
		b.logger.LogAttrs(ctx, slog.LevelInfo, "transcode job running")
		return nil
	}
	if err := worker.Publish(ctx, b.producer, id, res.ev); err != nil {
		b.logger.LogAttrs(ctx, slog.LevelWarn, "publish transcode result failed", slog.String("error", err.Error()))
		return err
	}
	attrs := []slog.Attr{slog.String("job_id", res.jobID())}
	if f := res.ev.GetTranscodeFailed(); f != nil {
		attrs = append(attrs, slog.String("outcome", "failed"), slog.String("reason", f.GetReason().String()),
			slog.String("detail", f.GetDetail()))
	} else {
		attrs = append(attrs, slog.String("outcome", "completed"))
	}
	b.logger.LogAttrs(ctx, slog.LevelInfo, "transcode result published", attrs...)
	// After the publish, so a retried publish counts once: failed for each delivery of the recorded
	// job's own ERROR message. The ready sample was recorded when the master was created.
	if res.ev.GetTranscodeFailed() != nil && res.job != nil && messageJob == res.jobID() {
		b.observe(ctx, res.job, "failed")
	}
	return nil
}

// observe records the time MediaConvert spent on job as a sample of svp.transcode.duration.
func (b *Bridge) observe(ctx context.Context, job *types.Job, outcome string) {
	if d, ok := processing(job); ok {
		b.transcodeDuration.Record(ctx, d.Seconds(), metric.WithAttributes(attribute.String("outcome", outcome)))
	}
}

// RunEvents receives the state changes of jobs from the SQS queue until ctx is canceled, then
// returns nil. A message is deleted only once it is settled: a message left (an error, a stop
// midway, one the bridge cannot vouch for) comes back after its visibility timeout.
func (b *Bridge) RunEvents(ctx context.Context) error {
	for ctx.Err() == nil {
		out, err := b.events.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
			QueueUrl:            &b.cfg.EventsQueueURL,
			MaxNumberOfMessages: receiveBatch,
			WaitTimeSeconds:     receiveWait,
		})
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			b.logger.WarnContext(ctx, "receive transcode events failed", slog.String("error", b.scrub(err)))
			select {
			case <-ctx.Done():
			case <-time.After(b.receiveRetry):
			}
			continue
		}
		for _, m := range out.Messages {
			if ctx.Err() != nil {
				break
			}
			if !b.HandleMessage(ctx, m.Body) {
				continue
			}
			if _, err := b.events.DeleteMessage(ctx, &sqs.DeleteMessageInput{
				QueueUrl: &b.cfg.EventsQueueURL, ReceiptHandle: m.ReceiptHandle,
			}); err != nil {
				b.logger.WarnContext(ctx, "delete transcode event failed", slog.String("error", b.scrub(err)))
			}
		}
	}
	return nil
}

// HandleMessage settles the job whose state change body carries and publishes the result, and
// reports whether the message is done with. A message the bridge cannot vouch for is logged and
// left for the redrive policy.
func (b *Bridge) HandleMessage(ctx context.Context, body *string) bool {
	jobID, err := parseEvent(body)
	if err != nil {
		b.logger.WarnContext(ctx, "transcode event ignored", slog.String("error", b.scrub(err)))
		return false
	}
	ctx = logx.With(ctx, slog.String("job_id", jobID))
	getCtx, cancel := context.WithTimeout(ctx, b.tryTimeout)
	job, err := b.getJob(getCtx, jobID)
	cancel()
	if err != nil {
		b.logger.WarnContext(ctx, "transcode event interrupted", slog.String("error", b.scrub(err)))
		return false
	}
	ref, err := b.checkJob(job)
	if err == nil && job.Status != types.JobStatusComplete && job.Status != types.JobStatusError {
		err = fmt.Errorf("job is %s, not COMPLETE or ERROR", job.Status)
	}
	if err != nil {
		b.logger.WarnContext(ctx, "transcode event ignored", slog.String("error", b.scrub(err)))
		return false
	}
	// The trace of the video.uploaded that created the job.
	ctx = logx.With(traceContext(ctx, ref.traceparent), slog.String("video_id", ref.videoID), slog.String("version", ref.version))
	res, err := b.try(ctx, ref.videoID, func(ctx context.Context, dir string) (settled, error) {
		return b.jobEnded(ctx, dir, ref, job)
	})
	if err != nil {
		b.logger.WarnContext(ctx, "transcode event interrupted", slog.String("error", b.scrub(err)))
		return false
	}
	return b.finish(ctx, ref.videoID, res, jobID) == nil
}

func (b *Bridge) scrub(err error) string { return worker.Scrub(b.cfg.WorkDir, err.Error()) }

// processing is the time MediaConvert spent on job, without its wait in the queue.
func processing(job *types.Job) (time.Duration, bool) {
	if job == nil || job.Timing == nil || job.Timing.StartTime == nil || job.Timing.FinishTime == nil {
		return 0, false
	}
	d := job.Timing.FinishTime.Sub(*job.Timing.StartTime)
	return d, d >= 0
}

// failedOf is the transcode.failed of video id.
func failedOf(id string, reason mediav1.TranscodeFailureReason, detail string) *mediav1.TranscodeEvent {
	return worker.Failed(id, reason, detail)
}
