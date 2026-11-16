// Command dlq-replay copies records of a dead-letter topic back to the topics they came from
// (package replay). Its pod runs standby and an operator execs replay in it.
//
// Subcommands:
//
//	standby  wait for SIGTERM, then exit 0; no Kafka, no telemetry (default when no subcommand is given)
//	replay   replay one dead-letter topic once, then exit
//
// replay flags:
//
//	--from <topic>        dead-letter topic to read, ending in .dlq (required)
//	--to <topic>          destination of every record (default: the record's dlq-topic header)
//	--partition <n>       read only partition n (default: all)
//	--start-offset <n>    first offset to read, inclusive (default: the first on the log)
//	--end-offset <n>      offset to stop at, exclusive (default: the high watermark at the start)
//	--since <RFC 3339>    first dead-letter time to read, inclusive
//	--until <RFC 3339>    dead-letter time to stop at, exclusive
//	--group <group>       only records whose dlq-group header is group
//	--dry-run             read and filter, produce nothing
//
// The time flags cannot be combined with the offset flags. Exit status: 0 when the range was
// replayed, 1 when the run stopped early (a produce or fetch error, SIGTERM; the summary line
// names the offset to resume from), 2 on a usage error.
//
// Configuration comes from the environment only: KAFKA_BROKERS (required) and the SASL variables
// kafkax.NewClient reads. There is no configuration file and no password flag. The OTEL_*
// variables send the replay's logs and its counter svp.dlq.replay.records to the Collector.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/anhnvcoder/svp-backend/internal/envcfg"
	"github.com/anhnvcoder/svp-backend/internal/logx"
	"github.com/anhnvcoder/svp-backend/internal/telemetry"
	"github.com/anhnvcoder/svp-backend/services/dlq-replay/internal/replay"
)

const serviceName = "dlq-replay"

// Exit statuses.
const (
	exitOK    = 0
	exitFail  = 1
	exitUsage = 2
)

func main() {
	logger := logx.New(serviceName)
	slog.SetDefault(logger)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	code := run(ctx, logger, os.Args[1:], os.Stderr)
	stop()
	os.Exit(code)
}

func run(ctx context.Context, logger *slog.Logger, args []string, stderr io.Writer) int {
	cmd := "standby"
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	switch cmd {
	case "standby":
		if len(args) > 0 {
			_, _ = fmt.Fprintln(stderr, "standby takes no arguments")
			return exitUsage
		}
		<-ctx.Done()
		return exitOK
	case "replay":
		cfg, err := parseReplay(args, stderr)
		if errors.Is(err, flag.ErrHelp) {
			return exitOK
		}
		if err != nil {
			_, _ = fmt.Fprintln(stderr, err)
			return exitUsage
		}
		if err := replayCmd(ctx, logger, cfg); err != nil {
			return exitFail
		}
		return exitOK
	}
	_, _ = fmt.Fprintf(stderr, "unknown command %q, want standby or replay\n", cmd)
	return exitUsage
}

// parseReplay reads the flags of replay; the error is a usage error.
func parseReplay(args []string, stderr io.Writer) (replay.Config, error) {
	cfg := replay.Config{ClientID: serviceName}
	var partition int
	var since, until string
	fs := flag.NewFlagSet("replay", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&cfg.From, "from", "", "dead-letter topic to read, ending in .dlq")
	fs.StringVar(&cfg.To, "to", "", "destination of every record (default: the dlq-topic header)")
	fs.IntVar(&partition, "partition", replay.Unset, "read only this partition (default: all)")
	fs.Int64Var(&cfg.StartOffset, "start-offset", replay.Unset, "first offset to read, inclusive")
	fs.Int64Var(&cfg.EndOffset, "end-offset", replay.Unset, "offset to stop at, exclusive")
	fs.StringVar(&since, "since", "", "first dead-letter time to read, RFC 3339, inclusive")
	fs.StringVar(&until, "until", "", "dead-letter time to stop at, RFC 3339, exclusive")
	fs.StringVar(&cfg.Group, "group", "", "only records whose dlq-group header is this group")
	fs.BoolVar(&cfg.DryRun, "dry-run", false, "read and filter, produce nothing")
	if err := fs.Parse(args); err != nil {
		return replay.Config{}, err
	}
	if fs.NArg() > 0 {
		return replay.Config{}, fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	if partition < replay.Unset || partition > 1<<31-1 {
		return replay.Config{}, errors.New("--partition is out of range")
	}
	cfg.Partition = int32(partition) //nolint:gosec // range checked above
	for _, t := range []struct {
		name, value string
		dst         *time.Time
	}{{"since", since, &cfg.Since}, {"until", until, &cfg.Until}} {
		if t.value == "" {
			continue
		}
		v, err := time.Parse(time.RFC3339, t.value)
		if err != nil {
			return replay.Config{}, fmt.Errorf("--%s is not an RFC 3339 time", t.name)
		}
		*t.dst = v
	}
	if err := cfg.Validate(); err != nil {
		return replay.Config{}, err
	}
	return cfg, nil
}

// replayCmd runs one replay with telemetry and logs its error itself, while the providers still
// take records; they are flushed before it returns, so the counter of a short run is exported.
func replayCmd(ctx context.Context, logger *slog.Logger, cfg replay.Config) error {
	fail := func(err error) error {
		logger.ErrorContext(ctx, "dlq-replay failed", slog.Any("error", err))
		return err
	}
	brokers, err := envcfg.Required("KAFKA_BROKERS")
	if err != nil {
		return fail(err)
	}
	cfg.Brokers = brokers
	shutdownTelemetry, err := telemetry.Setup(ctx, serviceName)
	if err != nil {
		return fail(fmt.Errorf("set up telemetry: %w", err))
	}
	defer flush(ctx, logger, shutdownTelemetry)
	if _, err := replay.Run(ctx, cfg, logger); err != nil {
		return fail(err)
	}
	return nil
}

func flush(ctx context.Context, logger *slog.Logger, shutdownTelemetry func(context.Context) error) {
	if err := shutdownTelemetry(context.WithoutCancel(ctx)); err != nil {
		logger.WarnContext(ctx, "telemetry shutdown failed", slog.Any("error", err))
	}
}
