// Package telemetrytest checks what a command exports through telemetry.Setup: a fake OTLP/gRPC
// Collector on a loopback port the test opens, and a way to run a test in a process of its own.
package telemetrytest

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"testing"

	collectorlog "go.opentelemetry.io/proto/otlp/collector/logs/v1"
	collectormetric "go.opentelemetry.io/proto/otlp/collector/metrics/v1"
	collectortrace "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	commonpb "go.opentelemetry.io/proto/otlp/common/v1"
	"google.golang.org/grpc"
)

// LogRecord is one log record a Collector received, with the attributes of its resource.
type LogRecord struct {
	Resource map[string]string
	Body     string
	Attrs    map[string]string
}

// Collector is a fake OTLP/gRPC Collector. It keeps the log records it receives and accepts traces
// and metrics without keeping them, so a shutdown of the providers reports no error.
type Collector struct {
	mu   sync.Mutex
	logs []LogRecord
}

// StartCollector starts a Collector, stopped when t ends, and points the OTLP exporters of
// telemetry.Setup at it. It clears the variables that would turn telemetry off, route a signal
// elsewhere or start the profiler.
func StartCollector(t *testing.T) *Collector {
	t.Helper()
	for _, name := range []string{"OTEL_SDK_DISABLED", "PYROSCOPE_SERVER_ADDRESS", "OTEL_TRACES_SAMPLER",
		"OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"} {
		t.Setenv(name, "")
	}
	var lc net.ListenConfig
	listener, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	c := &Collector{}
	server := grpc.NewServer()
	collectorlog.RegisterLogsServiceServer(server, logService{c: c})
	collectortrace.RegisterTraceServiceServer(server, traceService{})
	collectormetric.RegisterMetricsServiceServer(server, metricService{})
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://"+listener.Addr().String())
	t.Setenv("OTEL_EXPORTER_OTLP_INSECURE", "true")
	return c
}

// UnreachableCollector points the OTLP exporters of telemetry.Setup at a loopback port the test
// opened and closed again, a Collector that does not answer.
func UnreachableCollector(t *testing.T) {
	t.Helper()
	StartCollector(t)
	var lc net.ListenConfig
	listener, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://"+listener.Addr().String())
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
}

// Logs returns the log records received so far.
func (c *Collector) Logs() []LogRecord {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]LogRecord(nil), c.logs...)
}

type logService struct {
	collectorlog.UnimplementedLogsServiceServer
	c *Collector
}

func (s logService) Export(_ context.Context, req *collectorlog.ExportLogsServiceRequest) (*collectorlog.ExportLogsServiceResponse, error) {
	s.c.mu.Lock()
	defer s.c.mu.Unlock()
	for _, rl := range req.GetResourceLogs() {
		resource := attrs(rl.GetResource().GetAttributes())
		for _, sl := range rl.GetScopeLogs() {
			for _, r := range sl.GetLogRecords() {
				s.c.logs = append(s.c.logs, LogRecord{
					Resource: resource, Body: value(r.GetBody()), Attrs: attrs(r.GetAttributes()),
				})
			}
		}
	}
	return &collectorlog.ExportLogsServiceResponse{}, nil
}

type traceService struct {
	collectortrace.UnimplementedTraceServiceServer
}

func (traceService) Export(context.Context, *collectortrace.ExportTraceServiceRequest) (*collectortrace.ExportTraceServiceResponse, error) {
	return &collectortrace.ExportTraceServiceResponse{}, nil
}

type metricService struct {
	collectormetric.UnimplementedMetricsServiceServer
}

func (metricService) Export(context.Context, *collectormetric.ExportMetricsServiceRequest) (*collectormetric.ExportMetricsServiceResponse, error) {
	return &collectormetric.ExportMetricsServiceResponse{}, nil
}

func attrs(kvs []*commonpb.KeyValue) map[string]string {
	m := make(map[string]string, len(kvs))
	for _, kv := range kvs {
		m[kv.GetKey()] = value(kv.GetValue())
	}
	return m
}

func value(v *commonpb.AnyValue) string {
	switch x := v.GetValue().(type) {
	case *commonpb.AnyValue_StringValue:
		return x.StringValue
	case *commonpb.AnyValue_IntValue:
		return fmt.Sprint(x.IntValue)
	case *commonpb.AnyValue_BoolValue:
		return fmt.Sprint(x.BoolValue)
	case *commonpb.AnyValue_DoubleValue:
		return fmt.Sprint(x.DoubleValue)
	case nil:
		return ""
	}
	return v.String()
}

// childEnv marks a process started by InChild.
const childEnv = "SVP_TELEMETRYTEST_CHILD"

// InChild runs the calling test again in a child process of the test binary and reports whether
// the caller is that child. In the parent it fails t when the child fails, skips t when the child
// skipped, and returns the child's output (stdout and stderr), with inChild false.
//
// The OTel log bridge sends the records of a logger made before the first global provider to that
// provider for the life of the process: a command that builds its logger before telemetry.Setup,
// as main does, only exports from a process whose globals no other test has set.
func InChild(t *testing.T) (output string, inChild bool) {
	t.Helper()
	if os.Getenv(childEnv) != "" {
		return "", true
	}
	levels := strings.Split(t.Name(), "/")
	for i, level := range levels {
		levels[i] = "^" + regexp.QuoteMeta(level) + "$"
	}
	cmd := exec.CommandContext(t.Context(), os.Args[0], //nolint:gosec // the test binary itself
		"-test.run="+strings.Join(levels, "/"), "-test.count=1", "-test.v")
	cmd.Env = append(os.Environ(), childEnv+"=1")
	out, err := cmd.CombinedOutput()
	switch {
	case err == nil && strings.Contains(string(out), "--- PASS: "+t.Name()):
		return string(out), false
	case err == nil && strings.Contains(string(out), "--- SKIP: "+t.Name()):
		t.Skipf("child test skipped:\n%s", out)
	}
	t.Fatalf("child test: %v\n%s", err, out)
	return "", false
}
