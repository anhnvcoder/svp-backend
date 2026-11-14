package httpx

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// wantSecurityHeaders checks rec carries the headers of SecurityHeaders, with cacheControl.
func wantSecurityHeaders(t *testing.T, rec *httptest.ResponseRecorder, cacheControl string) {
	t.Helper()
	want := map[string]string{
		"X-Content-Type-Options":  "nosniff",
		"Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
		"Cache-Control":           cacheControl,
	}
	for k, v := range want {
		if got := rec.Header().Values(k); len(got) != 1 || got[0] != v {
			t.Errorf("%s = %q, want [%q]", k, got, v)
		}
	}
	for _, k := range []string{"Pragma", "Strict-Transport-Security", "X-Frame-Options"} {
		if got := rec.Header().Get(k); got != "" {
			t.Errorf("%s = %q, want none", k, got)
		}
	}
}

// TestSecurityHeaders runs the chain the gateway uses, so the 500 of Recover, the problem of
// Routes and a probe Trace leaves out are checked as the client sees them.
func TestSecurityHeaders(t *testing.T) {
	captureLog(t)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /json", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	})
	mux.HandleFunc("GET /cached", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Cache-Control", "public, max-age=30")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	})
	mux.HandleFunc("DELETE /thing", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /panic", func(http.ResponseWriter, *http.Request) { panic("boom") })
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	h := Trace(testServer, ClientAddr{})(SecurityHeaders(Recover(AccessLog(Routes(mux)))))

	for _, tc := range []struct {
		name, method, path string
		wantStatus         int
		wantType           string
		wantCache          string
		wantEmpty          bool
	}{
		{name: "json", method: http.MethodGet, path: "/json", wantStatus: http.StatusOK, wantType: "application/json", wantCache: "no-store"},
		{name: "handler sets cache", method: http.MethodGet, path: "/cached", wantStatus: http.StatusOK, wantType: "application/json", wantCache: "public, max-age=30"},
		{name: "no content", method: http.MethodDelete, path: "/thing", wantStatus: http.StatusNoContent, wantCache: "no-store", wantEmpty: true},
		{name: "panic", method: http.MethodGet, path: "/panic", wantStatus: http.StatusInternalServerError, wantType: "application/problem+json", wantCache: "no-store"},
		{name: "no route", method: http.MethodGet, path: "/nowhere", wantStatus: http.StatusNotFound, wantType: "application/problem+json", wantCache: "no-store"},
		{name: "wrong method", method: http.MethodPost, path: "/json", wantStatus: http.StatusMethodNotAllowed, wantType: "application/problem+json", wantCache: "no-store"},
		{name: "redirect to clean path", method: http.MethodGet, path: "/a/../json", wantStatus: http.StatusTemporaryRedirect, wantType: "text/html; charset=utf-8", wantCache: "no-store"},
		{name: "probe", method: http.MethodGet, path: "/healthz", wantStatus: http.StatusOK, wantType: "application/json", wantCache: "no-store"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), tc.method, tc.path, nil))
			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d (body %q)", rec.Code, tc.wantStatus, rec.Body.String())
			}
			wantSecurityHeaders(t, rec, tc.wantCache)
			if got := rec.Header().Get("Content-Type"); got != tc.wantType {
				t.Errorf("Content-Type = %q, want %q", got, tc.wantType)
			}
			if tc.wantEmpty && rec.Body.Len() != 0 {
				t.Errorf("body = %q, want empty", rec.Body.String())
			}
		})
	}
}
