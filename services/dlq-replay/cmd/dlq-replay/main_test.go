package main

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/anhnvcoder/svp-backend/internal/kafkax"
)

func TestStandbyExitsZeroWhenCanceled(t *testing.T) {
	for _, args := range [][]string{nil, {"standby"}} {
		ctx, cancel := context.WithCancel(t.Context())
		done := make(chan int, 1)
		go func() { done <- run(ctx, slog.New(slog.DiscardHandler), args, &bytes.Buffer{}) }()
		select {
		case code := <-done:
			t.Fatalf("args %v: exited %d before the cancel", args, code)
		case <-time.After(100 * time.Millisecond):
		}
		cancel()
		select {
		case code := <-done:
			if code != exitOK {
				t.Errorf("args %v: exit %d, want 0", args, code)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("args %v: standby did not return", args)
		}
	}
}

func TestUsageErrorsExitTwo(t *testing.T) {
	// No broker is reachable: a usage error must stop before any Kafka call.
	t.Setenv("KAFKA_BROKERS", "127.0.0.1:1")
	for name, args := range map[string][]string{
		"unknown command":   {"compact"},
		"standby with args": {"standby", "--from", "x.dlq"},
		"unknown flag":      {"replay", "--from", "video.lifecycle.v1.dlq", "--force"},
		"no from":           {"replay"},
		"from not dlq":      {"replay", "--from", "video.lifecycle.v1"},
		"bad since":         {"replay", "--from", "video.lifecycle.v1.dlq", "--since", "yesterday"},
		"offsets and time": {"replay", "--from", "video.lifecycle.v1.dlq", "--start-offset", "3",
			"--until", "2026-11-14T00:00:00Z"},
		"bad partition": {"replay", "--from", "video.lifecycle.v1.dlq", "--partition", "-3"},
		"big partition": {"replay", "--from", "video.lifecycle.v1.dlq", "--partition", "4294967296"},
		"extra arg":     {"replay", "--from", "video.lifecycle.v1.dlq", "now"},
		"bad offset":    {"replay", "--from", "video.lifecycle.v1.dlq", "--end-offset", "ten"},
	} {
		stderr := &bytes.Buffer{}
		if code := run(t.Context(), slog.New(slog.DiscardHandler), args, stderr); code != exitUsage {
			t.Errorf("%s: exit %d, want 2", name, code)
		}
		if stderr.Len() == 0 {
			t.Errorf("%s: nothing on stderr", name)
		}
	}
}

func TestReplayWithoutBrokersExitsOne(t *testing.T) {
	t.Setenv("KAFKA_BROKERS", "")
	logs := &bytes.Buffer{}
	code := run(t.Context(), slog.New(slog.NewJSONHandler(logs, nil)),
		[]string{"replay", "--from", "video.lifecycle.v1.dlq"}, &bytes.Buffer{})
	if code != exitFail || !strings.Contains(logs.String(), "KAFKA_BROKERS") {
		t.Errorf("exit %d, logs %s; want 1 naming KAFKA_BROKERS", code, logs)
	}
}

// A produce error exits 1, after a summary line naming the offset to resume from.
func TestReplayProduceErrorExitsOne(t *testing.T) {
	const dlq = "video.lifecycle.v1" + kafkax.DLQSuffix
	c, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(1, dlq))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	brokers := strings.Join(c.ListenAddrs(), ",")
	t.Setenv("KAFKA_BROKERS", brokers)
	t.Setenv("OTEL_SDK_DISABLED", "true")

	cl, err := kafkax.NewClient(brokers, "test-seed")
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	rec := &kgo.Record{Topic: dlq, Value: []byte("v"),
		Headers: []kgo.RecordHeader{{Key: kafkax.HeaderDLQTopic, Value: []byte("missing.v1")}}}
	if err := cl.ProduceSync(t.Context(), rec).FirstErr(); err != nil {
		t.Fatal(err)
	}

	logs := &bytes.Buffer{}
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	code := run(ctx, slog.New(slog.NewJSONHandler(logs, nil)), []string{"replay", "--from", dlq}, &bytes.Buffer{})
	if code != exitFail {
		t.Errorf("exit %d, want 1", code)
	}
	if !strings.Contains(logs.String(), `"resume_from":"0@0"`) || !strings.Contains(logs.String(), "dlq-replay failed") {
		t.Errorf("logs lack the resume offset or the failure:\n%s", logs)
	}
}

func TestHelpExitsZero(t *testing.T) {
	stderr := &bytes.Buffer{}
	if code := run(t.Context(), slog.New(slog.DiscardHandler), []string{"replay", "-h"}, stderr); code != exitOK {
		t.Errorf("exit %d, want 0", code)
	}
	if !strings.Contains(stderr.String(), "-from") {
		t.Errorf("help does not list the flags:\n%s", stderr)
	}
}
