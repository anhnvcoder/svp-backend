package httpx

import (
	"context"
	"net/http"

	"go.opentelemetry.io/otel"
)

// LoadShed returns a middleware that lets at most limit requests run in next at once and answers
// every request above that at once with 503 UNAVAILABLE and Retry-After: 1, counted in
// svp.gateway.requests.shed by the global OTel meter provider. It panics when limit is below 1.
// mux is the mux Routes serves: a refused request is named after its route in Trace's span and
// metric, as Routes would name it, so an SLO that selects routes counts the 503 against them.
// The probes /healthz and /readyz are neither limited nor counted, so a busy pod stays alive and
// ready instead of being restarted or taken out of its Service while it serves.
//
// The gateway limits itself because not every request crosses a proxy that could: the web's BFF
// calls it inside the cluster, past Envoy. The limit is per pod, so the capacity it protects grows
// with the replicas the HPA adds. A refused request is not queued: under overload a queue only
// adds its wait to every answer until requests time out anyway, while an immediate 503 lets the
// client retry on another pod or later. The slot is given back by a deferred call, so a panic, a
// client that goes away or a hijacked connection returns it too.
//
// Put it inside Trace, so a refused request still has its span and its http.server.request.duration
// point, and the SLOs count it as an error; and in front of the routes, so it reads no body, takes
// no rate limit token and makes no gRPC call. Each handler it wraps has its own limit.
func LoadShed(limit int, mux *http.ServeMux) func(http.Handler) http.Handler {
	if limit < 1 {
		panic("httpx: LoadShed needs a limit of at least 1")
	}
	shed, err := otel.Meter("github.com/anhnvcoder/svp-backend/services/gateway/internal/httpx").
		Int64Counter("svp.gateway.requests.shed")
	if err != nil {
		// The SDK still returns a working instrument along with the error.
		otel.Handle(err)
	}
	// Adding 0 creates the series before the first refusal; LoadShed runs at startup, with no request.
	shed.Add(context.Background(), 0)
	return func(next http.Handler) http.Handler {
		slots := make(chan struct{}, limit)
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if isProbe(r) {
				next.ServeHTTP(w, r)
				return
			}
			select {
			case slots <- struct{}{}:
			default:
				shed.Add(r.Context(), 1)
				if _, pattern := mux.Handler(r); pattern != "" {
					setRoute(r, pattern)
				}
				w.Header().Set("Retry-After", "1")
				WriteProblem(w, r, http.StatusServiceUnavailable, "UNAVAILABLE", "")
				return
			}
			defer func() { <-slots }()
			next.ServeHTTP(w, r)
		})
	}
}
