// Command media-worker consumes video.uploaded, transcodes the source to HLS and publishes the
// result. It has no database, no listening port and no gRPC.
//
// Subcommands:
//
//	serve         transcode with ffmpeg in the container (default when no subcommand is given)
//	mediaconvert  transcode with AWS Elemental MediaConvert: Probe and CreateJob for each
//	              video.uploaded, and the job state changes EventBridge sends to an SQS queue
//	              settle each version (package mediaconvert)
//
// The platform picks the subcommand; both publish the same events and store the same layout.
//
// Configuration comes from the environment: KAFKA_BROKERS and S3_ENDPOINT (required), the
// credential (S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY by default) and S3_PATH_STYLE as
// objstore.Config.ReadAccessEnv reads them, S3_REGION (default us-east-1), S3_UPLOADS_BUCKET
// (default uploads), S3_MEDIA_BUCKET (default media) and WORK_DIR (default /work). mediaconvert
// also requires MEDIACONVERT_QUEUE_ARN, MEDIACONVERT_ROLE_ARN and TRANSCODE_EVENTS_QUEUE_URL, all
// in the region S3_REGION, and calls MediaConvert and SQS with the credential of the store. A
// variable missing or malformed stops the command at startup. The OTEL_* variables send traces,
// metrics and logs to the Collector; the worker has no profiler and no error tracker, since its
// network reaches only Kafka, the object store, the AWS APIs and the Collector, and ffmpeg runs
// as a child process the profiler would not see.
//
// Design notes: docs/explanation/transcode.md.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"syscall"

	mcapi "github.com/aws/aws-sdk-go-v2/service/mediaconvert"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"golang.org/x/sync/errgroup"

	"github.com/anhnvcoder/svp-backend/internal/envcfg"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/logx"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/internal/telemetry"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/mediaconvert"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/worker"

	// Deprecated upstream; the same instrumentation objstore uses for S3, see there.
	"go.opentelemetry.io/contrib/instrumentation/github.com/aws/aws-sdk-go-v2/otelaws" //nolint:staticcheck // see above
)

const serviceName = "media-worker"

func main() {
	logger := logx.New(serviceName)
	slog.SetDefault(logger)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, logger, os.Args[1:])
	stop()
	if err != nil {
		if _, logged := errors.AsType[loggedError](err); !logged {
			logger.Error("media-worker failed", slog.Any("error", err))
		}
		os.Exit(1)
	}
}

// loggedError is an error serve has logged already, while the telemetry providers still took
// records, so main does not log it again.
type loggedError struct{ error }

func (e loggedError) Unwrap() error { return e.error }

func run(ctx context.Context, logger *slog.Logger, args []string) error {
	cmd := "serve"
	if len(args) > 0 {
		cmd = args[0]
	}
	switch cmd {
	case "serve":
		return serve(ctx, logger)
	case "mediaconvert":
		return bridge(ctx, logger)
	}
	return fmt.Errorf("unknown command %q, want serve or mediaconvert", cmd)
}

type config struct {
	brokers string
	store   objstore.Config
	workDir string
}

func loadConfig() (config, error) {
	cfg := config{
		store: objstore.Config{
			Region:        envcfg.String("S3_REGION", "us-east-1"),
			UploadsBucket: envcfg.String("S3_UPLOADS_BUCKET", "uploads"),
			MediaBucket:   envcfg.String("S3_MEDIA_BUCKET", "media"),
		},
		workDir: envcfg.String("WORK_DIR", "/work"),
	}
	required := []struct {
		name string
		dst  *string
	}{
		{"KAFKA_BROKERS", &cfg.brokers},
		{"S3_ENDPOINT", &cfg.store.Endpoint},
	}
	for _, r := range required {
		v, err := envcfg.Required(r.name)
		if err != nil {
			return config{}, err
		}
		*r.dst = v
	}
	// A malformed endpoint would fail every request at run time, and after the retries every
	// video as RETRIES_EXHAUSTED: stop at startup instead.
	if err := checkEndpoint("S3_ENDPOINT", cfg.store.Endpoint); err != nil {
		return config{}, err
	}
	if err := cfg.store.ReadAccessEnv(); err != nil {
		return config{}, err
	}
	return cfg, nil
}

// checkEndpoint requires an absolute http or https URL with a host, such as http://s3:9000.
func checkEndpoint(name, value string) error {
	u, err := url.Parse(value)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("%s must be an absolute http or https URL", name)
	}
	return nil
}

// bridgeConfig is what mediaconvert needs on top of config.
type bridgeConfig struct {
	config
	queueARN, roleARN, eventsQueueURL string
}

// Shapes of the bridge's AWS resources; the region is checked against S3_REGION apart.
var (
	queueARNPattern = regexp.MustCompile(`^arn:aws[a-z-]*:mediaconvert:([a-z0-9-]+):[0-9]{12}:queues/[A-Za-z0-9_-]{1,128}$`)
	roleARNPattern  = regexp.MustCompile(`^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]{1,512}$`)
	sqsURLPattern   = regexp.MustCompile(`^https://sqs\.([a-z0-9-]+)\.amazonaws\.com/[0-9]{12}/[A-Za-z0-9_-]{1,80}$`)
)

func loadBridgeConfig() (bridgeConfig, error) {
	base, err := loadConfig()
	if err != nil {
		return bridgeConfig{}, err
	}
	cfg := bridgeConfig{config: base}
	for _, v := range []struct {
		name    string
		dst     *string
		pattern *regexp.Regexp
	}{
		{"MEDIACONVERT_QUEUE_ARN", &cfg.queueARN, queueARNPattern},
		{"MEDIACONVERT_ROLE_ARN", &cfg.roleARN, roleARNPattern},
		{"TRANSCODE_EVENTS_QUEUE_URL", &cfg.eventsQueueURL, sqsURLPattern},
	} {
		value, err := envcfg.Required(v.name)
		if err != nil {
			return bridgeConfig{}, err
		}
		m := v.pattern.FindStringSubmatch(value)
		if m == nil {
			return bridgeConfig{}, fmt.Errorf("%s is malformed", v.name)
		}
		// One region per environment: a queue elsewhere would fail every call at run time.
		if len(m) > 1 && m[1] != cfg.store.Region {
			return bridgeConfig{}, fmt.Errorf("%s is not in the region S3_REGION names", v.name)
		}
		*v.dst = value
	}
	return cfg, nil
}

// bridge runs the mediaconvert command: the consumer of video.uploaded and the loop over the
// state changes of jobs, until ctx is canceled or one of them fails. Neither publishes half a
// result: a record or message in hand when ctx ends is left to be delivered again.
func bridge(ctx context.Context, logger *slog.Logger) (err error) {
	cfg, err := loadBridgeConfig()
	if err != nil {
		return err
	}
	shutdownTelemetry, err := telemetry.Setup(ctx, serviceName)
	if err != nil {
		return fmt.Errorf("set up telemetry: %w", err)
	}
	defer func() {
		if err != nil {
			logger.ErrorContext(ctx, "media-worker failed", slog.Any("error", err))
			err = loggedError{err}
		}
		if err := shutdownTelemetry(context.WithoutCancel(ctx)); err != nil {
			logger.WarnContext(ctx, "telemetry shutdown failed", slog.Any("error", err))
		}
	}()
	store, err := objstore.New(cfg.store)
	if err != nil {
		return err
	}
	creds, err := objstore.CallCredentials(cfg.store)
	if err != nil {
		return err
	}
	// Built from options rather than config.LoadDefaultConfig, as objstore does, so no other
	// credential than the store's is picked up.
	mc := mcapi.New(mcapi.Options{Region: cfg.store.Region, Credentials: creds},
		func(o *mcapi.Options) { otelaws.AppendMiddlewares(&o.APIOptions) })
	events := sqs.New(sqs.Options{Region: cfg.store.Region, Credentials: creds},
		func(o *sqs.Options) { otelaws.AppendMiddlewares(&o.APIOptions) })
	producer, err := kafkax.NewClient(cfg.brokers, serviceName)
	if err != nil {
		return fmt.Errorf("KAFKA_BROKERS: %w", err)
	}
	defer producer.Close()

	if err := worker.CleanWorkDir(cfg.workDir); err != nil {
		return err
	}
	b := mediaconvert.New(mediaconvert.Config{
		QueueARN: cfg.queueARN, RoleARN: cfg.roleARN, EventsQueueURL: cfg.eventsQueueURL,
		UploadsBucket: cfg.store.UploadsBucket, MediaBucket: cfg.store.MediaBucket, WorkDir: cfg.workDir,
	}, mc, events, store, producer, logger)
	consumer, err := kafkax.NewConsumer(b.ConsumerConfig(cfg.brokers))
	if err != nil {
		return err
	}
	logger.InfoContext(ctx, "media-worker started", slog.String("command", "mediaconvert"),
		slog.String("topic", worker.InputTopic), slog.String("group", worker.Group))
	g, gctx := errgroup.WithContext(ctx)
	g.Go(func() error { return consumer.Run(gctx) })
	g.Go(func() error { return b.RunEvents(gctx) })
	if err := g.Wait(); err != nil {
		return err
	}
	logger.InfoContext(ctx, "media-worker stopped")
	return nil
}

// serve runs the consumer until ctx is canceled (SIGINT, SIGTERM). The job in hand is then
// canceled: ffmpeg is killed, nothing is published or committed, and the record is delivered
// again to whichever worker takes the partition.
func serve(ctx context.Context, logger *slog.Logger) (err error) {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	// Providers first, so the clients below report to them. Export is asynchronous: a Collector
	// that cannot be reached loses telemetry, never a job.
	shutdownTelemetry, err := telemetry.Setup(ctx, serviceName)
	if err != nil {
		return fmt.Errorf("set up telemetry: %w", err)
	}
	// Deferred first, so it runs last: after the consumer has stopped and the producer closed, a
	// failure is logged while the providers still take it, then they export what they recorded.
	defer func() {
		if err != nil {
			logger.ErrorContext(ctx, "media-worker failed", slog.Any("error", err))
			err = loggedError{err}
		}
		if err := shutdownTelemetry(context.WithoutCancel(ctx)); err != nil {
			logger.WarnContext(ctx, "telemetry shutdown failed", slog.Any("error", err))
		}
	}()
	store, err := objstore.New(cfg.store)
	if err != nil {
		return err
	}
	producer, err := kafkax.NewClient(cfg.brokers, serviceName)
	if err != nil {
		return fmt.Errorf("KAFKA_BROKERS: %w", err)
	}
	defer producer.Close()

	w := worker.New(store, producer, cfg.workDir, logger)
	if err := w.CleanWorkDir(); err != nil {
		return err
	}
	consumer, err := kafkax.NewConsumer(w.ConsumerConfig(cfg.brokers))
	if err != nil {
		return err
	}
	logger.InfoContext(ctx, "media-worker started", slog.String("topic", worker.InputTopic), slog.String("group", worker.Group))
	if err := consumer.Run(ctx); err != nil {
		return err
	}
	logger.InfoContext(ctx, "media-worker stopped")
	return nil
}
