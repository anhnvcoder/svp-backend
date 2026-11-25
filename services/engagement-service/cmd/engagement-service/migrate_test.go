package main

import (
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/anhnvcoder/svp-backend/internal/logx"
	"github.com/anhnvcoder/svp-backend/internal/pgtest"
	"github.com/anhnvcoder/svp-backend/internal/telemetry/telemetrytest"
	"github.com/anhnvcoder/svp-backend/services/engagement-service/migrations"
)

// migrate exports its records to the Collector, tagged with the service and the pod, and they
// have left when it returns, on success and on failure; stdout keeps them. Each case runs in a
// process of its own, with the logger made before telemetry.Setup as in main.
func TestMigrateExportsLogsBeforeReturning(t *testing.T) {
	t.Run("success", func(t *testing.T) {
		out, child := telemetrytest.InChild(t)
		if !child {
			if !strings.Contains(out, `"msg":"migration settings"`) {
				t.Errorf("stdout lacks the migration settings record:\n%s", out)
			}
			return
		}
		pool := pgtest.New(t, "svp_engagement_migrate_cmd_test", migrations.FS)
		t.Setenv("DATABASE_URL", pool.Config().ConnString())
		collector := telemetrytest.StartCollector(t)
		t.Setenv("OTEL_RESOURCE_ATTRIBUTES", "k8s.pod.name=engagement-service-migrate-x")
		logger := logx.New(serviceName)
		slog.SetDefault(logger)
		if err := migrate(t.Context(), logger); err != nil {
			t.Fatal(err)
		}
		r, ok := findLog(collector.Logs(), "migration settings")
		if !ok || r.Resource["service.name"] != serviceName || r.Resource["k8s.pod.name"] != "engagement-service-migrate-x" ||
			r.Attrs["lock_timeout"] == "" {
			t.Errorf("exported records = %+v, want migration settings with its lock_timeout from %s's pod",
				collector.Logs(), serviceName)
		}
	})
	// A Collector that does not answer neither fails the migration nor holds the command past the
	// shutdown budget of telemetry.Setup.
	t.Run("collector down", func(t *testing.T) {
		if _, child := telemetrytest.InChild(t); !child {
			return
		}
		pool := pgtest.New(t, "svp_engagement_migrate_cmd_down_test", migrations.FS)
		t.Setenv("DATABASE_URL", pool.Config().ConnString())
		telemetrytest.UnreachableCollector(t)
		logger := logx.New(serviceName)
		slog.SetDefault(logger)
		start := time.Now()
		if err := migrate(t.Context(), logger); err != nil {
			t.Fatal(err)
		}
		if elapsed := time.Since(start); elapsed > 10*time.Second {
			t.Errorf("migrate took %s, want the shutdown bounded", elapsed)
		}
	})
	// A failure is logged while the providers still export, once (main skips a loggedError), and
	// no record carries the password of DATABASE_URL.
	t.Run("failure", func(t *testing.T) {
		const password = "fake-password-for-test"
		out, child := telemetrytest.InChild(t)
		if !child {
			if !strings.Contains(out, `"msg":"engagement-service failed"`) || strings.Contains(out, password) {
				t.Errorf("stdout lacks the failure or shows the password:\n%s", out)
			}
			return
		}
		// Refused when parsed, before any connection, so no retry delays the failure.
		t.Setenv("DATABASE_URL", "postgres://svp_migrator:"+password+"@127.0.0.1:1/svp?sslmode=bogus")
		collector := telemetrytest.StartCollector(t)
		logger := logx.New(serviceName)
		slog.SetDefault(logger)
		err := migrate(t.Context(), logger)
		if _, logged := errors.AsType[loggedError](err); !logged {
			t.Fatalf("migrate() = %v, want an error marked as logged", err)
		}
		r, ok := findLog(collector.Logs(), "engagement-service failed")
		if !ok || r.Resource["service.name"] != serviceName || !strings.Contains(r.Attrs["exception.message"], "sslmode") {
			t.Errorf("exported records = %+v, want the failure with its error", collector.Logs())
		}
		if all := fmt.Sprint(collector.Logs()); strings.Contains(all, password) {
			t.Errorf("an exported record shows the password: %s", all)
		}
	})
}

func findLog(logs []telemetrytest.LogRecord, body string) (telemetrytest.LogRecord, bool) {
	for _, r := range logs {
		if r.Body == body {
			return r, true
		}
	}
	return telemetrytest.LogRecord{}, false
}
