package main

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"testing"

	"go.opentelemetry.io/otel"

	"github.com/anhnvcoder/svp-backend/internal/objstore"
)

func setRequired(t *testing.T) {
	t.Helper()
	t.Setenv("KAFKA_BROKERS", "kafka:9096")
	t.Setenv("S3_ENDPOINT", "http://s3:9000")
	t.Setenv("S3_ACCESS_KEY_ID", "svp-media-worker")
	t.Setenv("S3_SECRET_ACCESS_KEY", "test-secret-value")
	for _, name := range []string{"S3_REGION", "S3_UPLOADS_BUCKET", "S3_MEDIA_BUCKET", "WORK_DIR", "S3_CREDENTIALS",
		"S3_PATH_STYLE", "AWS_CONTAINER_CREDENTIALS_FULL_URI", "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE"} {
		t.Setenv(name, "")
	}
}

func TestLoadConfigDefaults(t *testing.T) {
	setRequired(t)
	cfg, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	s := cfg.store
	if cfg.brokers != "kafka:9096" || s.Endpoint != "http://s3:9000" || s.AccessKeyID != "svp-media-worker" ||
		s.SecretAccessKey != "test-secret-value" {
		t.Errorf("required values not read: %+v", cfg)
	}
	if s.Region != "us-east-1" || s.UploadsBucket != "uploads" || s.MediaBucket != "media" || cfg.workDir != "/work" {
		t.Errorf("defaults = %q %q %q %q", s.Region, s.UploadsBucket, s.MediaBucket, cfg.workDir)
	}
}

func TestLoadConfigMissingNamesVariable(t *testing.T) {
	for _, name := range []string{"KAFKA_BROKERS", "S3_ENDPOINT", "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY"} {
		t.Run(name, func(t *testing.T) {
			setRequired(t)
			t.Setenv(name, "")
			_, err := loadConfig()
			if err == nil || !strings.Contains(err.Error(), name) {
				t.Errorf("err = %v, want one naming %s", err, name)
			}
		})
	}
}

// On EKS: the credential of Pod Identity, the bucket in the host name, and no static key.
func TestLoadConfigContainerCredentials(t *testing.T) {
	setRequired(t)
	t.Setenv("S3_ACCESS_KEY_ID", "")
	t.Setenv("S3_SECRET_ACCESS_KEY", "")
	t.Setenv("S3_ENDPOINT", "https://s3.ap-southeast-1.amazonaws.com")
	t.Setenv("S3_CREDENTIALS", "container")
	t.Setenv("S3_PATH_STYLE", "false")
	t.Setenv("AWS_CONTAINER_CREDENTIALS_FULL_URI", "http://169.254.170.23/v1/credentials")
	t.Setenv("AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE", "/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token")
	cfg, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	s := cfg.store
	if s.Credentials != objstore.CredentialsContainer || !s.VirtualHosted || s.AccessKeyID != "" ||
		s.ContainerCredentialsURI != "http://169.254.170.23/v1/credentials" {
		t.Errorf("store config = %+v", s)
	}
	if _, err := objstore.New(s); err != nil {
		t.Errorf("objstore.New() of the container config: %v", err)
	}
}

func TestLoadConfigRejectsBadAccessSettings(t *testing.T) {
	for _, tc := range []struct{ variable, value string }{
		{"S3_CREDENTIALS", "env"},
		// The static key of setRequired is still set.
		{"S3_CREDENTIALS", "container"},
		{"S3_PATH_STYLE", "0"},
	} {
		t.Run(tc.variable+"="+tc.value, func(t *testing.T) {
			setRequired(t)
			t.Setenv(tc.variable, tc.value)
			_, err := loadConfig()
			if err == nil || !strings.Contains(err.Error(), tc.variable) {
				t.Fatalf("err = %v, want one naming %s", err, tc.variable)
			}
			if strings.Contains(err.Error(), "test-secret-value") {
				t.Errorf("err %q prints the secret", err)
			}
		})
	}
}

func TestLoadConfigRejectsMalformedEndpoint(t *testing.T) {
	for _, value := range []string{"s3:9000", "127.0.0.1:9000", "ftp://s3:9000", "http://", "/s3"} {
		t.Run(value, func(t *testing.T) {
			setRequired(t)
			t.Setenv("S3_ENDPOINT", value)
			_, err := loadConfig()
			if err == nil || !strings.Contains(err.Error(), "S3_ENDPOINT") {
				t.Fatalf("err = %v, want one naming S3_ENDPOINT", err)
			}
			if strings.Contains(err.Error(), value) {
				t.Errorf("err %q prints the value", err)
			}
		})
	}
}

func TestLoadConfigAcceptsHTTPSEndpoint(t *testing.T) {
	setRequired(t)
	t.Setenv("S3_ENDPOINT", "https://s3.us-east-1.amazonaws.com")
	if _, err := loadConfig(); err != nil {
		t.Fatal(err)
	}
}

func TestRunRejectsOtherCommands(t *testing.T) {
	t.Parallel()
	for _, cmd := range []string{"migrate", "healthcheck"} {
		if err := run(t.Context(), nil, []string{cmd}); err == nil {
			t.Errorf("run(%q) = nil, want an error", cmd)
		}
	}
}

func TestServeMalformedKafkaBrokersNamesTheVariable(t *testing.T) {
	setRequired(t)
	t.Setenv("WORK_DIR", t.TempDir())
	for _, brokers := range []string{" , ", "kafka:notaport"} {
		t.Setenv("KAFKA_BROKERS", brokers)
		err := serve(t.Context(), slog.New(slog.DiscardHandler))
		if err == nil || !strings.Contains(err.Error(), "KAFKA_BROKERS") {
			t.Errorf("KAFKA_BROKERS=%q: serve() = %v, want an error naming KAFKA_BROKERS", brokers, err)
		}
	}
}

// probedError is an ERROR record and whether the tracer provider of telemetry.Setup was still
// open when it was logged. That provider shuts down together with the logger and meter
// providers, so it stands for all three.
type probedError struct {
	message   string
	telemetry bool
}

// failureProbe is a slog handler noting each ERROR record and whether the telemetry providers
// still took records.
type failureProbe struct {
	mu     sync.Mutex
	errors []probedError
}

func (*failureProbe) Enabled(context.Context, slog.Level) bool { return true }

func (p *failureProbe) Handle(ctx context.Context, r slog.Record) error {
	if r.Level < slog.LevelError {
		return nil
	}
	_, span := otel.Tracer("probe").Start(ctx, "probe")
	e := probedError{message: r.Message, telemetry: span.IsRecording()}
	span.End()
	p.mu.Lock()
	defer p.mu.Unlock()
	p.errors = append(p.errors, e)
	return nil
}

func (p *failureProbe) WithAttrs([]slog.Attr) slog.Handler { return p }
func (p *failureProbe) WithGroup(string) slog.Handler      { return p }

func (p *failureProbe) logged() []probedError {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]probedError(nil), p.errors...)
}

// A failure once the providers are set up is logged while they still take records, so it reaches
// the Collector, and is marked so main does not log it again. A configuration error comes before
// there is anything to report to, and is left to main.
func TestServeLogsFailureBeforeClosingTelemetry(t *testing.T) {
	setRequired(t)
	t.Setenv("WORK_DIR", t.TempDir())
	// Telemetry records but exports nowhere.
	for _, name := range []string{"OTEL_SDK_DISABLED", "OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_TRACES_SAMPLER"} {
		t.Setenv(name, "")
	}
	// Checked after telemetry is set up.
	t.Setenv("KAFKA_BROKERS", "kafka:notaport")
	probe := &failureProbe{}
	err := serve(t.Context(), slog.New(probe))
	if err == nil || !strings.Contains(err.Error(), "KAFKA_BROKERS") {
		t.Fatalf("serve() = %v, want an error naming KAFKA_BROKERS", err)
	}
	if _, ok := errors.AsType[loggedError](err); !ok {
		t.Error("serve() error is not marked as logged: main would log it a second time")
	}
	want := probedError{message: "media-worker failed", telemetry: true}
	if got := probe.logged(); len(got) != 1 || got[0] != want {
		t.Errorf("ERROR records = %+v, want [%+v]", got, want)
	}

	t.Setenv("KAFKA_BROKERS", "")
	early := &failureProbe{}
	err = serve(t.Context(), slog.New(early))
	if _, ok := errors.AsType[loggedError](err); err == nil || ok {
		t.Errorf("serve() without KAFKA_BROKERS = %v, want an error left to main", err)
	}
	if got := early.logged(); len(got) != 0 {
		t.Errorf("ERROR records for a configuration error = %+v, want none", got)
	}
}

// setBridge sets what mediaconvert requires on top of setRequired, in region ap-southeast-1.
func setBridge(t *testing.T) {
	t.Helper()
	setRequired(t)
	t.Setenv("S3_REGION", "ap-southeast-1")
	t.Setenv("MEDIACONVERT_QUEUE_ARN", "arn:aws:mediaconvert:ap-southeast-1:000000000000:queues/svp-stg")
	t.Setenv("MEDIACONVERT_ROLE_ARN", "arn:aws:iam::000000000000:role/svp-stg-mediaconvert")
	t.Setenv("TRANSCODE_EVENTS_QUEUE_URL", "https://sqs.ap-southeast-1.amazonaws.com/000000000000/svp-stg-transcode-events")
}

func TestLoadBridgeConfig(t *testing.T) {
	setBridge(t)
	cfg, err := loadBridgeConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.queueARN == "" || cfg.roleARN == "" || cfg.eventsQueueURL == "" || cfg.brokers != "kafka:9096" ||
		cfg.store.Region != "ap-southeast-1" {
		t.Errorf("config = %+v", cfg)
	}
}

// Each variable of mediaconvert is required and checked for its shape and region at startup;
// the error names the variable, never its value.
func TestLoadBridgeConfigRejects(t *testing.T) {
	for _, tc := range []struct{ variable, value string }{
		{"MEDIACONVERT_QUEUE_ARN", ""},
		{"MEDIACONVERT_ROLE_ARN", ""},
		{"TRANSCODE_EVENTS_QUEUE_URL", ""},
		{"MEDIACONVERT_QUEUE_ARN", "arn:aws:mediaconvert:ap-southeast-1:000000000000:presets/svp-stg"},
		{"MEDIACONVERT_QUEUE_ARN", "arn:aws:mediaconvert:us-east-1:000000000000:queues/svp-stg"},
		{"MEDIACONVERT_ROLE_ARN", "arn:aws:iam::000000000000:user/svp-stg"},
		{"TRANSCODE_EVENTS_QUEUE_URL", "http://sqs.ap-southeast-1.amazonaws.com/000000000000/svp-stg-transcode-events"},
		{"TRANSCODE_EVENTS_QUEUE_URL", "https://sqs.us-east-1.amazonaws.com/000000000000/svp-stg-transcode-events"},
		{"TRANSCODE_EVENTS_QUEUE_URL", "https://evil.example/000000000000/svp-stg-transcode-events"},
	} {
		t.Run(tc.variable+"="+tc.value, func(t *testing.T) {
			setBridge(t)
			t.Setenv(tc.variable, tc.value)
			_, err := loadBridgeConfig()
			if err == nil || !strings.Contains(err.Error(), tc.variable) {
				t.Fatalf("err = %v, want one naming %s", err, tc.variable)
			}
			if tc.value != "" && strings.Contains(err.Error(), tc.value) {
				t.Errorf("err %q prints the value", err)
			}
		})
	}
}

// mediaconvert stops at startup, before any client exists, when a variable is missing.
func TestBridgeMissingQueueNamesTheVariable(t *testing.T) {
	setBridge(t)
	t.Setenv("MEDIACONVERT_QUEUE_ARN", "")
	err := run(t.Context(), slog.New(slog.DiscardHandler), []string{"mediaconvert"})
	if err == nil || !strings.Contains(err.Error(), "MEDIACONVERT_QUEUE_ARN") {
		t.Errorf("run(mediaconvert) = %v, want an error naming MEDIACONVERT_QUEUE_ARN", err)
	}
}
