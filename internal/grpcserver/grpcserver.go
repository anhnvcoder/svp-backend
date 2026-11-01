// Package grpcserver runs a service's gRPC server with the interceptors and health service every
// service shares, and checks a running server's health.
package grpcserver

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"runtime/debug"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"

	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc/filters"
)

// shutdownTimeout bounds GracefulStop; after it, in-flight RPCs are cut off by Stop.
const shutdownTimeout = 10 * time.Second

// healthCheckMethod is the RPC Healthcheck and the compose health checks call.
const healthCheckMethod = "/grpc.health.v1.Health/Check"

// readinessService is the health service name the readiness probe asks for. It is SERVING while
// the service's readiness check passes; the overall health "" does not depend on it.
const readinessService = "readiness"

// The readiness check runs every readinessInterval, each run bounded by readinessTimeout (shorter
// than the interval, so two runs never overlap). readinessFailures failures in a row turn
// readiness NOT_SERVING, so one slow check does not; one pass turns it SERVING again.
const (
	readinessInterval = 2 * time.Second
	readinessTimeout  = time.Second
	readinessFailures = 3
)

// readiness is the background check that sets the status of readinessService.
type readiness struct {
	check    func(context.Context) error
	interval time.Duration
	timeout  time.Duration
	failures int
}

// Run listens on addr and serves gRPC until ctx is done, then stops gracefully. It returns an
// error when it cannot listen or serving fails, and nil after a shutdown caused by ctx.
//
// register adds the service's handlers. Every RPC but the health check gets a server span and
// the rpc.server.call.duration metric from the otelgrpc stats handler, which continues the trace
// of the metadata traceparent (a new root trace when it is missing or malformed), using the
// global OTel providers and propagator. Every unary RPC then passes, in order, through: the RPC
// log line, panic recovery, then interceptors.
//
// The standard health service reports the overall health "" SERVING from the moment the server
// listens until shutdown starts, whatever ready returns: liveness must not depend on anything
// outside the process. The service name "readiness" starts NOT_SERVING and follows ready, the
// check that the service can serve RPCs (a ping of its database pool), run in the background
// until ctx is done. Shutdown turns both NOT_SERVING.
func Run(ctx context.Context, addr string, logger *slog.Logger, register func(*grpc.Server), ready func(context.Context) error, interceptors ...grpc.UnaryServerInterceptor) error {
	var lc net.ListenConfig
	lis, err := lc.Listen(ctx, "tcp", addr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", addr, err)
	}
	r := readiness{check: ready, interval: readinessInterval, timeout: readinessTimeout, failures: readinessFailures}
	return serve(ctx, lis, logger, register, r, interceptors...)
}

func serve(ctx context.Context, lis net.Listener, logger *slog.Logger, register func(*grpc.Server), ready readiness, interceptors ...grpc.UnaryServerInterceptor) error {
	chain := append([]grpc.UnaryServerInterceptor{logInterceptor(logger), recoverInterceptor(logger)}, interceptors...)
	srv := grpc.NewServer(
		// Docker probes the health check every 10 s: no span or metric for it.
		grpc.StatsHandler(otelgrpc.NewServerHandler(otelgrpc.WithFilter(filters.Not(filters.FullMethodName(healthCheckMethod))))),
		grpc.ChainUnaryInterceptor(chain...),
	)

	hs := health.NewServer()
	// Registered before the server listens: a name the health service does not know answers
	// NOT_FOUND, which a probe counts as a failure but which says nothing about the database.
	hs.SetServingStatus(readinessService, healthpb.HealthCheckResponse_NOT_SERVING)
	healthpb.RegisterHealthServer(srv, hs)
	register(srv)

	readyCtx, stopReady := context.WithCancel(ctx)
	readyDone := make(chan struct{})
	go func() {
		defer close(readyDone)
		ready.run(readyCtx, hs, logger)
	}()
	defer func() {
		stopReady()
		<-readyDone
	}()

	errCh := make(chan error, 1)
	go func() { errCh <- srv.Serve(lis) }()
	logger.InfoContext(ctx, "grpc server listening", slog.String("addr", lis.Addr().String()))

	select {
	case err := <-errCh:
		return fmt.Errorf("serve grpc: %w", err)
	case <-ctx.Done():
	}

	// Report NOT_SERVING first so health checks stop routing traffic here while RPCs drain.
	hs.Shutdown()
	logger.Info("grpc server stopping")
	stopped := make(chan struct{})
	go func() {
		srv.GracefulStop()
		close(stopped)
	}()
	timer := time.NewTimer(shutdownTimeout)
	defer timer.Stop()
	select {
	case <-stopped:
	case <-timer.C:
		logger.Warn("graceful stop timed out, closing remaining connections", slog.Duration("timeout", shutdownTimeout))
		srv.Stop()
		<-stopped
	}
	if err := <-errCh; err != nil && !errors.Is(err, grpc.ErrServerStopped) {
		return fmt.Errorf("serve grpc: %w", err)
	}
	logger.Info("grpc server stopped")
	return nil
}

// run sets the status of readinessService from the check, first at once and then every interval,
// until ctx is done. It logs a line when the status changes, not on every check. After hs.Shutdown
// the health service ignores status changes, so a check that ends during shutdown changes nothing.
func (r readiness) run(ctx context.Context, hs *health.Server, logger *slog.Logger) {
	ticker := time.NewTicker(r.interval)
	defer ticker.Stop()
	serving := false
	failed := 0
	for {
		checkCtx, cancel := context.WithTimeout(ctx, r.timeout)
		err := r.check(checkCtx)
		cancel()
		if ctx.Err() != nil {
			return
		}
		switch {
		case err == nil:
			failed = 0
			if !serving {
				serving = true
				hs.SetServingStatus(readinessService, healthpb.HealthCheckResponse_SERVING)
				logger.Info("grpc readiness serving")
			}
		case serving:
			failed++
			if failed >= r.failures {
				serving = false
				hs.SetServingStatus(readinessService, healthpb.HealthCheckResponse_NOT_SERVING)
				logger.Warn("grpc readiness not serving", slog.Int("failed_checks", failed), slog.String("error", err.Error()))
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// logInterceptor writes one line per RPC: method, status code and duration. Request and
// response bodies are never logged, since they can hold passwords and tokens. The line is at
// ERROR for the codes that mean a fault of the server (UNKNOWN, INTERNAL, DATA_LOSS), so the error
// tracker gets it, and at INFO otherwise.
func logInterceptor(logger *slog.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		start := time.Now()
		resp, err := handler(ctx, req)
		code := status.Code(err)
		level := slog.LevelInfo
		switch code {
		case codes.Unknown, codes.Internal, codes.DataLoss:
			level = slog.LevelError
		}
		logger.LogAttrs(ctx, level, "rpc",
			slog.String("method", info.FullMethod),
			slog.String("code", code.String()),
			slog.Float64("duration_ms", float64(time.Since(start).Microseconds())/1000),
		)
		return resp, err
	}
}

// recoverInterceptor turns a panic in the handler or a later interceptor into INTERNAL with a
// generic message; the panic value and stack go to the log only.
func recoverInterceptor(logger *slog.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp any, err error) {
		defer func() {
			if r := recover(); r != nil {
				logger.LogAttrs(ctx, slog.LevelError, "panic in grpc handler",
					slog.String("method", info.FullMethod),
					slog.Any("panic", r),
					slog.String("stack", string(debug.Stack())),
				)
				resp, err = nil, status.Error(codes.Internal, "internal error")
			}
		}()
		return handler(ctx, req)
	}
}

// Healthcheck asks the server at addr for its overall health over an insecure connection and
// returns nil only when it is SERVING. Bound the call with a deadline on ctx.
func Healthcheck(ctx context.Context, addr string) error {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return fmt.Errorf("create grpc client for %s: %w", addr, err)
	}
	defer func() { _ = conn.Close() }()

	resp, err := healthpb.NewHealthClient(conn).Check(ctx, &healthpb.HealthCheckRequest{})
	if err != nil {
		return fmt.Errorf("health check %s: %w", addr, err)
	}
	if s := resp.GetStatus(); s != healthpb.HealthCheckResponse_SERVING {
		return fmt.Errorf("health check %s: status %s", addr, s)
	}
	return nil
}
