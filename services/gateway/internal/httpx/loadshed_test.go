package httpx

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync"
	"testing"
	"time"

	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
)

// shedCount returns the value of svp.gateway.requests.shed, and whether the series exists.
func shedCount(t *testing.T, reader *sdkmetric.ManualReader) (int64, bool) {
	t.Helper()
	var data metricdata.ResourceMetrics
	if err := reader.Collect(t.Context(), &data); err != nil {
		t.Fatal(err)
	}
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			sum, ok := m.Data.(metricdata.Sum[int64])
			if m.Name != "svp.gateway.requests.shed" || !ok {
				continue
			}
			if !sum.IsMonotonic || len(sum.DataPoints) != 1 || sum.DataPoints[0].Attributes.Len() != 0 {
				t.Fatalf("shed metric = %+v, want one counter series without attributes", sum)
			}
			return sum.DataPoints[0].Value, true
		}
	}
	return 0, false
}

// blocking is a handler whose requests to /block wait until release is closed; entered gets one
// value per request that got in. Every other path answers 204 at once.
type blocking struct {
	entered chan struct{}
	release chan struct{}
}

func newBlocking() *blocking {
	return &blocking{entered: make(chan struct{}, 100), release: make(chan struct{})}
}

// shedding returns b on a mux of the routes the tests call, behind LoadShed with limit and that mux.
func shedding(limit int, b *blocking) http.Handler {
	mux := http.NewServeMux()
	for _, route := range []string{"GET /block", "GET /x", "GET /healthz", "GET /readyz"} {
		mux.Handle(route, b)
	}
	return LoadShed(limit, mux)(mux)
}

func (b *blocking) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/block" {
		b.entered <- struct{}{}
		<-b.release
	}
	w.WriteHeader(http.StatusNoContent)
}

// fill sends n requests to /block through h and waits until all of them run in the handler. The
// returned function lets them finish and waits for their answers.
func (b *blocking) fill(t *testing.T, h http.Handler, n int) (done func()) {
	t.Helper()
	var wg sync.WaitGroup
	for range n {
		wg.Go(func() {
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/block", nil))
			if rec.Code != http.StatusNoContent {
				t.Errorf("held request: status %d, want 204", rec.Code)
			}
		})
	}
	for range n {
		select {
		case <-b.entered:
		case <-time.After(5 * time.Second):
			t.Fatal("held requests did not reach the handler")
		}
	}
	return func() {
		close(b.release)
		wg.Wait()
	}
}

func get(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, path, nil))
	return rec
}

func TestLoadShedRefusesAboveLimit(t *testing.T) {
	const limit = 3
	b := newBlocking()
	h := shedding(limit, b)
	done := b.fill(t, h, limit)

	rec := get(t, h, "/x")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("request %d: status %d, want 503", limit+1, rec.Code)
	}
	if ra := rec.Header().Get("Retry-After"); ra != "1" {
		t.Errorf("Retry-After = %q, want 1", ra)
	}
	if p := decodeProblem(t, rec); p.Code != "UNAVAILABLE" || p.Detail != "" {
		t.Errorf("problem code %q, detail %q; want UNAVAILABLE without detail", p.Code, p.Detail)
	}
	if len(b.entered) != 0 {
		t.Error("a refused request reached the handler")
	}

	done()
	if rec := get(t, h, "/x"); rec.Code != http.StatusNoContent {
		t.Errorf("after the held requests ended: status %d, want 204", rec.Code)
	}
}

func TestLoadShedLetsProbesThrough(t *testing.T) {
	reader := readMetrics(t)
	b := newBlocking()
	h := shedding(1, b)
	done := b.fill(t, h, 1)
	defer done()

	for _, path := range []string{"/healthz", "/readyz"} {
		if rec := get(t, h, path); rec.Code != http.StatusNoContent {
			t.Errorf("%s while full: status %d, want the handler's 204", path, rec.Code)
		}
	}
	// Only the exact paths pass.
	if rec := get(t, h, "/healthz/x"); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("/healthz/x while full: status %d, want 503", rec.Code)
	}
	if n, _ := shedCount(t, reader); n != 1 {
		t.Errorf("shed = %d, want 1: the probes are not counted", n)
	}
}

func TestLoadShedCountsRefusals(t *testing.T) {
	reader := readMetrics(t)
	b := newBlocking()
	h := shedding(2, b)
	if n, ok := shedCount(t, reader); !ok || n != 0 {
		t.Fatalf("shed before any request = %d (exists %v), want a series at 0", n, ok)
	}
	done := b.fill(t, h, 2)
	for range 3 {
		get(t, h, "/x")
	}
	done()
	get(t, h, "/x")
	if n, _ := shedCount(t, reader); n != 3 {
		t.Errorf("shed = %d, want 3", n)
	}
}

func TestLoadShedSpanAndMetricInsideTrace(t *testing.T) {
	reader := readMetrics(t)
	spans := recordSpans(t)
	b := newBlocking()
	h := Trace(testServer, ClientAddr{})(shedding(1, b))
	done := b.fill(t, h, 1)
	rec := get(t, h, "/x")
	done()

	if p := decodeProblem(t, rec); p.TraceID == "" {
		t.Error("refused request: trace_id is empty")
	}
	var series []string
	for _, p := range durationPoints(t, reader) {
		route, _ := p.Attributes.Value("http.route")
		code, _ := p.Attributes.Value("http.response.status_code")
		series = append(series, fmt.Sprintf("%s %d", route.AsString(), code.AsInt64()))
	}
	slices.Sort(series)
	if want := []string{"/block 204", "/x 503"}; !slices.Equal(series, want) {
		t.Errorf("duration series = %q, want %q", series, want)
	}
	var names []string
	for _, s := range spans.Ended() {
		names = append(names, s.Name())
	}
	if !slices.Contains(names, "GET /x") {
		t.Errorf("span names = %q, want one GET /x for the refused request", names)
	}
}

// TestLoadShedReturnsSlot: the slot comes back however the handler ends. Each case runs with a
// limit of 1 on a real server, so the next request gets in only when the slot came back.
func TestLoadShedReturnsSlot(t *testing.T) {
	for name, end := range map[string]http.HandlerFunc{
		"panic": func(http.ResponseWriter, *http.Request) {
			panic(http.ErrAbortHandler)
		},
		"client gone": func(_ http.ResponseWriter, r *http.Request) {
			<-r.Context().Done()
		},
		"hijacked": func(w http.ResponseWriter, _ *http.Request) {
			conn, rw, err := http.NewResponseController(w).Hijack()
			if err != nil {
				t.Errorf("hijack: %v", err)
				return
			}
			_, _ = rw.WriteString("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
			_ = rw.Flush()
			_ = conn.Close()
		},
	} {
		t.Run(name, func(t *testing.T) {
			// returned gets a value after LoadShed itself returned, so its deferred release ran.
			returned := make(chan struct{}, 2)
			mux := http.NewServeMux()
			mux.Handle("GET /end", end)
			mux.HandleFunc("GET /x", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
			shed := LoadShed(1, mux)(mux)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				defer func() { returned <- struct{}{} }()
				shed.ServeHTTP(w, r)
			}))
			defer srv.Close()

			ctx, cancel := context.WithCancel(t.Context())
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/end", nil)
			if err != nil {
				t.Fatal(err)
			}
			if name == "client gone" {
				time.AfterFunc(50*time.Millisecond, cancel)
			}
			if resp, err := srv.Client().Do(req); err == nil {
				_ = resp.Body.Close()
			}
			cancel()
			select {
			case <-returned:
			case <-time.After(5 * time.Second):
				t.Fatal("handler did not return")
			}

			next, err := http.NewRequestWithContext(t.Context(), http.MethodGet, srv.URL+"/x", nil)
			if err != nil {
				t.Fatal(err)
			}
			resp, err := srv.Client().Do(next)
			if err != nil {
				t.Fatal(err)
			}
			_ = resp.Body.Close()
			if resp.StatusCode != http.StatusNoContent {
				t.Errorf("next request: status %d, want 204: the slot was not given back", resp.StatusCode)
			}
		})
	}
}

func TestLoadShedRejectsLimitBelowOne(t *testing.T) {
	for _, limit := range []int{0, -1} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("LoadShed(%d) did not panic", limit)
				}
			}()
			LoadShed(limit, http.NewServeMux())
		}()
	}
}
