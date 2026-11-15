package objstore

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

func testConfig(endpoint string) Config {
	return Config{ //nolint:gosec // a dummy credential, never sent anywhere real
		Endpoint:        endpoint,
		Region:          "us-east-1",
		AccessKeyID:     "svp-test",
		SecretAccessKey: "not-a-real-secret",
		UploadsBucket:   "uploads",
		MediaBucket:     "media",
	}
}

func newTestStore(t *testing.T, cfg Config) *Store {
	t.Helper()
	s, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestNewRejectsMissingConfig(t *testing.T) {
	t.Parallel()
	for _, field := range []string{"Endpoint", "Region", "AccessKeyID", "SecretAccessKey", "UploadsBucket", "MediaBucket"} {
		cfg := testConfig("http://s3:9000")
		switch field {
		case "Endpoint":
			cfg.Endpoint = ""
		case "Region":
			cfg.Region = ""
		case "AccessKeyID":
			cfg.AccessKeyID = ""
		case "SecretAccessKey":
			cfg.SecretAccessKey = ""
		case "UploadsBucket":
			cfg.UploadsBucket = ""
		case "MediaBucket":
			cfg.MediaBucket = ""
		}
		_, err := New(cfg)
		if err == nil || !strings.Contains(err.Error(), field) {
			t.Errorf("New() without %s: error = %v, want one naming the field", field, err)
		}
	}
}

func TestBucketByPrefix(t *testing.T) {
	t.Parallel()
	cfg := testConfig("http://s3:9000")
	cfg.UploadsBucket, cfg.MediaBucket = "up-bucket", "media-bucket"
	s := newTestStore(t, cfg)
	tests := []struct {
		key, want string
	}{
		{"uploads/0192", "up-bucket"},
		{"media/0192/master.m3u8", "media-bucket"},
		{"media/0192/", "media-bucket"},
		{"premium/0192/v/a/index_360p_00001.ts", "media-bucket"},
		{"preview/0192/v/master.m3u8", "media-bucket"},
		{"transcode-jobs/0192/0193.json", "media-bucket"},
		{"premium/", ""},
		{"preview/", ""},
		{"premium0192", ""},
		{"transcode-jobs/", ""},
		{"transcode-jobs0192", ""},
		{"uploads/", ""},
		{"media/", ""},
		{"", ""},
		{"other/0192", ""},
		{"Uploads/0192", ""},
		{"/uploads/0192", ""},
		{"uploads0192", ""},
	}
	for _, tt := range tests {
		got, err := s.bucket(tt.key)
		if tt.want == "" {
			if !errors.Is(err, ErrInvalidKey) {
				t.Errorf("bucket(%q) = %q, %v; want ErrInvalidKey", tt.key, got, err)
			}
			continue
		}
		if err != nil || got != tt.want {
			t.Errorf("bucket(%q) = %q, %v; want %q", tt.key, got, err, tt.want)
		}
	}
}

func decodePolicy(t *testing.T, policy string) (string, []any) {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(policy)
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Expiration string `json:"expiration"`
		Conditions []any  `json:"conditions"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	return doc.Expiration, doc.Conditions
}

func TestPresignPostPolicy(t *testing.T) {
	cfg := testConfig("http://s3:9000")
	cfg.PublicEndpoint = "http://127.0.0.1:9000"
	s := newTestStore(t, cfg)
	const key = "uploads/0192a7b4-5c3e-7d2f-8a1b-3c4d5e6f7a8b"

	before := time.Now()
	post, err := s.PresignPost(t.Context(), key, 1234, "video/mp4", 15*time.Minute)
	if err != nil {
		t.Fatal(err)
	}

	if post.URL != "http://127.0.0.1:9000/uploads" {
		t.Errorf("URL = %q, want the public endpoint plus the bucket", post.URL)
	}
	for _, f := range []string{"key", "policy", "Content-Type", "X-Amz-Algorithm", "X-Amz-Credential", "X-Amz-Date", "X-Amz-Signature"} {
		if post.Fields[f] == "" {
			t.Errorf("field %s missing", f)
		}
	}
	if post.Fields["key"] != key || post.Fields["Content-Type"] != "video/mp4" {
		t.Errorf("key, Content-Type fields = %q, %q", post.Fields["key"], post.Fields["Content-Type"])
	}
	if !strings.HasPrefix(post.Fields["X-Amz-Credential"], "svp-test/") {
		t.Errorf("X-Amz-Credential = %q, want the access key of the store", post.Fields["X-Amz-Credential"])
	}

	exp, conds := decodePolicy(t, post.Fields["policy"])
	if got := post.ExpiresAt.UTC().Format(time.RFC3339); got != exp {
		t.Errorf("ExpiresAt = %s, policy expiration = %s", got, exp)
	}
	if d := post.ExpiresAt.Sub(before); d < 15*time.Minute-time.Second || d > 15*time.Minute+2*time.Second {
		t.Errorf("ExpiresAt is %v after signing, want 15m", d)
	}

	want := map[string]bool{
		`{"bucket":"uploads"}`:                   false,
		`{"key":"` + key + `"}`:                  false,
		`{"Content-Type":"video/mp4"}`:           false,
		`["content-length-range",1,1234]`:        false,
		`{"X-Amz-Algorithm":"AWS4-HMAC-SHA256"}`: false,
	}
	keyConds := 0
	for _, c := range conds {
		b, err := json.Marshal(c)
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := want[string(b)]; ok {
			want[string(b)] = true
		}
		if strings.Contains(string(b), "starts-with") {
			t.Errorf("policy has a prefix condition %s; key, bucket and type must match exactly", b)
		}
		if strings.Contains(string(b), `"key"`) || strings.Contains(string(b), `$key`) {
			keyConds++
		}
	}
	for c, found := range want {
		if !found {
			t.Errorf("policy lacks condition %s; conditions: %v", c, conds)
		}
	}
	if keyConds != 1 {
		t.Errorf("policy has %d key conditions, want exactly one", keyConds)
	}
}

func TestPresignPostRejects(t *testing.T) {
	t.Parallel()
	s := newTestStore(t, testConfig("http://s3:9000"))
	tests := []struct {
		name, key, contentType string
		size                   int64
		ttl                    time.Duration
	}{
		{"media key", "media/0192/master.m3u8", "video/mp4", 10, time.Minute},
		{"other prefix", "other/0192", "video/mp4", 10, time.Minute},
		{"bare prefix", "uploads/", "video/mp4", 10, time.Minute},
		{"zero size", "uploads/0192", "video/mp4", 0, time.Minute},
		{"no content type", "uploads/0192", "", 10, time.Minute},
		{"no ttl", "uploads/0192", "video/mp4", 10, 0},
	}
	for _, tt := range tests {
		post, err := s.PresignPost(t.Context(), tt.key, tt.size, tt.contentType, tt.ttl)
		if err == nil || post != nil {
			t.Errorf("%s: PresignPost() = %v, %v; want an error", tt.name, post, err)
		}
	}
}

func TestHeadClassifiesErrors(t *testing.T) {
	t.Parallel()
	tests := []struct {
		status    int
		want      error
		permanent bool
	}{
		{http.StatusNotFound, ErrNotFound, true},
		{http.StatusForbidden, ErrAccessDenied, true},
		{http.StatusServiceUnavailable, nil, false},
	}
	for _, tt := range tests {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(tt.status)
		}))
		s := newTestStore(t, testConfig(srv.URL))
		_, err := s.Head(t.Context(), "uploads/v1")
		srv.Close()
		if err == nil {
			t.Fatalf("HTTP %d: Head() succeeded", tt.status)
		}
		if tt.want != nil && !errors.Is(err, tt.want) {
			t.Errorf("HTTP %d: error = %v, want %v", tt.status, err, tt.want)
		}
		if !tt.permanent && (errors.Is(err, ErrNotFound) || errors.Is(err, ErrAccessDenied)) {
			t.Errorf("HTTP %d: error = %v classified as permanent, want temporary", tt.status, err)
		}
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", "42")
		w.Header().Set("Content-Type", "video/mp4")
	}))
	defer srv.Close()
	info, err := newTestStore(t, testConfig(srv.URL)).Head(t.Context(), "uploads/v1")
	if err != nil || info != (ObjectInfo{Size: 42, ContentType: "video/mp4"}) {
		t.Errorf("Head() = %+v, %v; want size 42, video/mp4", info, err)
	}
}

// fakeGet serves GET /uploads/uploads/<id> with body, chunked when chunked is true (no
// Content-Length), and 404 for any other path.
func fakeGet(t *testing.T, body string, chunked bool) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/uploads/uploads/v1" {
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`<Error><Code>NoSuchKey</Code></Error>`))
			return
		}
		if chunked {
			_, _ = w.Write([]byte(body[:1]))
			w.(http.Flusher).Flush()
			_, _ = w.Write([]byte(body[1:]))
			return
		}
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// staleFile writes a file where Download will write, as an earlier attempt would leave it.
func staleFile(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "src")
	if err := os.WriteFile(path, []byte("stale content from an earlier attempt"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestDownload(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		chunked bool
		max     int64
		wantErr error
	}{
		{"within limit", false, 10, nil},
		{"exactly the limit, chunked", true, 10, nil},
		{"over the limit by length", false, 9, ErrTooLarge},
		{"over the limit while streaming", true, 9, ErrTooLarge},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			srv := fakeGet(t, "0123456789", tt.chunked)
			s := newTestStore(t, testConfig(srv.URL))
			path := staleFile(t)
			err := s.Download(t.Context(), "uploads/v1", path, tt.max)
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("Download() error = %v, want %v", err, tt.wantErr)
			}
			got, rerr := os.ReadFile(path) //nolint:gosec // a file this test downloaded
			if tt.wantErr != nil {
				if !errors.Is(rerr, os.ErrNotExist) {
					t.Errorf("file left behind after %v (read error %v)", err, rerr)
				}
				return
			}
			if string(got) != "0123456789" {
				t.Errorf("file = %q", got)
			}
		})
	}

	t.Run("not found", func(t *testing.T) {
		t.Parallel()
		srv := fakeGet(t, "0123456789", false)
		s := newTestStore(t, testConfig(srv.URL))
		path := staleFile(t)
		if err := s.Download(t.Context(), "uploads/v2", path, 10); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Download() error = %v, want ErrNotFound", err)
		}
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("file exists after a failed download: %v", err)
		}
	})
}

func TestDeletePrefixRejects(t *testing.T) {
	t.Parallel()
	s := newTestStore(t, testConfig("http://svp-unreachable.invalid:9000"))
	for _, p := range []string{"media/", "media/0192", "other/0192/", ""} {
		if err := s.DeletePrefix(t.Context(), p); !errors.Is(err, ErrInvalidKey) {
			t.Errorf("DeletePrefix(%q) error = %v, want ErrInvalidKey", p, err)
		}
	}
}

// The keys media-worker writes pass; anything a storage or a URL parser could read as another
// path, or naming another video, does not.
func TestIsMediaKey(t *testing.T) {
	t.Parallel()
	const id = "0190a6e4-7b2c-7d3e-9f40-123456789abc"
	const prefix = "media/" + id + "/"
	tests := []struct {
		key  string
		want bool
	}{
		{prefix + "master.m3u8", true},
		{prefix + "thumbnail.jpg", true},
		{prefix + "720p/index.m3u8", true},
		{prefix + "720p/seg_007.ts", true},
		{prefix + "...", true},
		// The versioned layout: master under the version, the rest under the try's directory.
		{prefix + "0190a6e4-7b2c-7d3e-9f40-0000000000a1/master.m3u8", true},
		{prefix + "0190a6e4-7b2c-7d3e-9f40-0000000000a1/0190a6e4-7b2c-7d3e-9f40-0000000000b2/thumbnail.jpg", true},
		{prefix + "0190a6e4-7b2c-7d3e-9f40-0000000000a1/0190a6e4-7b2c-7d3e-9f40-0000000000b2/720p/seg_007.ts", true},
		{prefix + "0190a6e4-7b2c-7d3e-9f40-0000000000a1/../master.m3u8", false},
		{prefix, false},
		{"media/" + id, false},
		{"media/0190a6e4-7b2c-7d3e-9f40-123456789abd/master.m3u8", false},
		{"media/" + id + "x/master.m3u8", false},
		{"media//master.m3u8", false},
		{"uploads/" + id, false},
		{"x" + prefix + "master.m3u8", false},
		{prefix + "..", false},
		{prefix + "../x", false},
		{prefix + "./master.m3u8", false},
		{prefix + "720p//index.m3u8", false},
		{prefix + "720p/", false},
		{prefix + "/master.m3u8", false},
		{prefix + "%2e%2e/x", false},
		{prefix + ".%2E/x", false},
		{prefix + `..\x`, false},
		{prefix + `720p\index.m3u8`, false},
		{prefix + "master.m3u8?x=1", false},
		{prefix + "master.m3u8#x", false},
		{prefix + "a b", false},
		{prefix + "a\tb", false},
		{prefix + "a:b", false},
		{prefix + "mäster.m3u8", false},
	}
	for _, tt := range tests {
		if got := IsMediaKey(tt.key, id); got != tt.want {
			t.Errorf("IsMediaKey(%q, %q) = %v, want %v", tt.key, id, got, tt.want)
		}
	}
}

// IsKeyUnder applies the rule of IsMediaKey under each media prefix it is given, and only under it;
// any other prefix is refused whatever the key.
func TestIsKeyUnder(t *testing.T) {
	t.Parallel()
	const id = "0190a6e4-7b2c-7d3e-9f40-123456789abc"
	const other = "0190a6e4-7b2c-7d3e-9f40-123456789abd"
	const dir = id + "/0190a6e4-7b2c-7d3e-9f40-0000000000a1/0190a6e4-7b2c-7d3e-9f40-0000000000b2/"
	tests := []struct {
		prefix, key string
		want        bool
	}{
		{PremiumPrefix, PremiumPrefix + dir + "index_360p_00001.ts", true},
		{PremiumPrefix, PremiumPrefix + id + "/0190a6e4-7b2c-7d3e-9f40-0000000000a1/master.m3u8", true},
		{PreviewPrefix, PreviewPrefix + dir + "thumbnail.jpg", true},
		{MediaPrefix, MediaPrefix + dir + "index_720p.m3u8", true},
		// The prefix of the key must be the one asked for.
		{PremiumPrefix, MediaPrefix + dir + "index_360p_00001.ts", false},
		{PremiumPrefix, PreviewPrefix + dir + "index_360p_00001.ts", false},
		{PreviewPrefix, PremiumPrefix + dir + "index_360p_00001.ts", false},
		{MediaPrefix, PremiumPrefix + dir + "index_360p_00001.ts", false},
		// Prefixes outside the three media ones are refused, even when the key matches them.
		{UploadsPrefix, UploadsPrefix + id + "/x", false},
		{JobsPrefix, JobsPrefix + id + "/x", false},
		{"", id + "/x", false},
		{"premium", "premium" + id + "/x", false},
		{"premium//", "premium//" + id + "/x", false},
		// Another video, and paths that climb out or that a URL parser reads differently.
		{PremiumPrefix, PremiumPrefix + other + "/v/a/index_360p_00001.ts", false},
		{PremiumPrefix, PremiumPrefix + id + "x/v/a/index_360p_00001.ts", false},
		{PremiumPrefix, PremiumPrefix + dir + "../index_360p_00001.ts", false},
		{PremiumPrefix, PremiumPrefix + id + "/../" + other + "/v/a/x.ts", false},
		{PremiumPrefix, PremiumPrefix + dir + "%2e%2e/x.ts", false},
		{PremiumPrefix, PremiumPrefix + dir + "%2E%2E/x.ts", false},
		{PreviewPrefix, PreviewPrefix + id + "/./x", false},
		{PreviewPrefix, PreviewPrefix + id + "/a//x", false},
		{PreviewPrefix, PreviewPrefix + id + `/a\x`, false},
		{PremiumPrefix, PremiumPrefix + id + "/", false},
		{PremiumPrefix, PremiumPrefix + id, false},
	}
	for _, tt := range tests {
		if got := IsKeyUnder(tt.prefix, tt.key, id); got != tt.want {
			t.Errorf("IsKeyUnder(%q, %q, %q) = %v, want %v", tt.prefix, tt.key, id, got, tt.want)
		}
	}
}

// PresignGet signs a GET of one premium key on the public endpoint, for exactly ttl, without
// sending anything; other prefixes and out-of-range ttls are refused.
func TestPresignGet(t *testing.T) {
	t.Parallel()
	cfg := testConfig("http://svp-unreachable.invalid:9000")
	cfg.PublicEndpoint = "http://127.0.0.1:9000"
	s := newTestStore(t, cfg)
	const key = "premium/0190a6e4-7b2c-7d3e-9f40-123456789abc/v/a/index_360p_00001.ts"

	for _, ttl := range []time.Duration{time.Second, 1234 * time.Second, time.Hour} {
		raw, err := s.PresignGet(t.Context(), key, ttl)
		if err != nil {
			t.Fatalf("PresignGet(ttl %v) error = %v", ttl, err)
		}
		u, err := url.Parse(raw)
		if err != nil {
			t.Fatal(err)
		}
		if u.Scheme+"://"+u.Host != cfg.PublicEndpoint || u.Path != "/media/"+key {
			t.Errorf("URL = %s, want the public endpoint, the media bucket and the key", raw)
		}
		q := u.Query()
		if got, want := q.Get("X-Amz-Expires"), strconv.Itoa(int(ttl/time.Second)); got != want {
			t.Errorf("X-Amz-Expires = %q, want %q", got, want)
		}
		if q.Get("X-Amz-Algorithm") != "AWS4-HMAC-SHA256" || q.Get("X-Amz-Signature") == "" ||
			!strings.HasPrefix(q.Get("X-Amz-Credential"), "svp-test/") || q.Get("X-Amz-SignedHeaders") != "host" {
			t.Errorf("query = %v, want a SigV4 query signature of the host only", q)
		}
	}

	tests := []struct {
		name, key string
		ttl       time.Duration
	}{
		{"media key", "media/0190/v/a/index_360p_00001.ts", time.Minute},
		{"preview key", "preview/0190/v/a/index_360p_00001.ts", time.Minute},
		{"upload key", "uploads/0190", time.Minute},
		{"bare prefix", "premium/", time.Minute},
		{"no ttl", key, 0},
		{"under a second", key, time.Second - time.Nanosecond},
		{"over an hour", key, time.Hour + time.Second},
	}
	for _, tt := range tests {
		if raw, err := s.PresignGet(t.Context(), tt.key, tt.ttl); err == nil || raw != "" {
			t.Errorf("%s: PresignGet() = %q, %v; want an error", tt.name, raw, err)
		}
	}
}

// Read returns a small object whole, refuses one over the limit whether or not the length is
// sent, and classifies errors as Head does.
func TestRead(t *testing.T) {
	t.Parallel()
	const key = "premium/v1/e1/master.m3u8"
	tests := []struct {
		name    string
		status  int
		chunked bool
		max     int64
		wantErr error
	}{
		{"within limit", http.StatusOK, false, 10, nil},
		{"exactly the limit, chunked", http.StatusOK, true, 10, nil},
		{"over the limit by length", http.StatusOK, false, 9, ErrTooLarge},
		{"over the limit while streaming", http.StatusOK, true, 9, ErrTooLarge},
		{"not found", http.StatusNotFound, false, 10, ErrNotFound},
		{"denied", http.StatusForbidden, false, 10, ErrAccessDenied},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet || r.URL.Path != "/media/"+key {
					t.Errorf("request %s %s, want GET of the key in the media bucket", r.Method, r.URL.Path)
				}
				if tt.status != http.StatusOK {
					w.Header().Set("Content-Type", "application/xml")
					w.WriteHeader(tt.status)
					_, _ = w.Write([]byte(`<Error><Code>X</Code></Error>`))
					return
				}
				const body = "0123456789"
				if tt.chunked {
					_, _ = w.Write([]byte(body[:1]))
					w.(http.Flusher).Flush()
					_, _ = w.Write([]byte(body[1:]))
					return
				}
				_, _ = w.Write([]byte(body))
			}))
			defer srv.Close()
			got, err := newTestStore(t, testConfig(srv.URL)).Read(t.Context(), key, tt.max)
			if !errors.Is(err, tt.wantErr) || (tt.wantErr == nil) != (err == nil) {
				t.Fatalf("Read() error = %v, want %v", err, tt.wantErr)
			}
			if tt.wantErr == nil && string(got) != "0123456789" {
				t.Errorf("Read() = %q", got)
			}
			if tt.wantErr != nil && got != nil {
				t.Errorf("Read() = %q with an error, want nil", got)
			}
		})
	}

	s := newTestStore(t, testConfig("http://svp-unreachable.invalid:9000"))
	for _, k := range []string{"other/v1", "premium/", ""} {
		if _, err := s.Read(t.Context(), k, 10); !errors.Is(err, ErrInvalidKey) {
			t.Errorf("Read(%q) error = %v, want ErrInvalidKey", k, err)
		}
	}
}

// Upload sends Cache-Control only when it is given; Create adds If-None-Match: * and turns the
// 412 of a key that is taken into ErrExists, which is neither ErrAccessDenied nor ErrNotFound.
func TestPutHeaders(t *testing.T) {
	t.Parallel()
	type sent struct{ method, path, contentType, cacheControl, ifNoneMatch string }
	var got []sent
	taken := "/media/media/v1/master.m3u8"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, sent{r.Method, r.URL.Path, r.Header.Get("Content-Type"), r.Header.Get("Cache-Control"),
			r.Header.Get("If-None-Match")})
		if r.URL.Path == taken && r.Header.Get("If-None-Match") == "*" {
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusPreconditionFailed)
			_, _ = w.Write([]byte(`<Error><Code>PreconditionFailed</Code></Error>`))
		}
	}))
	defer srv.Close()
	s := newTestStore(t, testConfig(srv.URL))
	f := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(f, []byte("#EXTM3U\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	const immutable = "max-age=31536000, immutable"

	if err := s.Upload(t.Context(), "media/v1/a/360p/seg_000.ts", f, "video/mp2t", immutable); err != nil {
		t.Fatalf("Upload() error = %v", err)
	}
	if err := s.Upload(t.Context(), "uploads/v1", f, "video/mp4", ""); err != nil {
		t.Fatalf("Upload() without cache control: %v", err)
	}
	if err := s.Create(t.Context(), "media/v2/master.m3u8", f, "application/vnd.apple.mpegurl", immutable); err != nil {
		t.Fatalf("Create() of a free key: %v", err)
	}
	err := s.Create(t.Context(), "media/v1/master.m3u8", f, "application/vnd.apple.mpegurl", immutable)
	if !errors.Is(err, ErrExists) || errors.Is(err, ErrAccessDenied) || errors.Is(err, ErrNotFound) {
		t.Errorf("Create() of a taken key: error = %v, want only ErrExists", err)
	}

	want := []sent{
		{http.MethodPut, "/media/media/v1/a/360p/seg_000.ts", "video/mp2t", immutable, ""},
		{http.MethodPut, "/uploads/uploads/v1", "video/mp4", "", ""},
		{http.MethodPut, "/media/media/v2/master.m3u8", "application/vnd.apple.mpegurl", immutable, "*"},
		{http.MethodPut, taken, "application/vnd.apple.mpegurl", immutable, "*"},
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("requests:\n%v\nwant\n%v", got, want)
	}
}

// Exists lists with the key as prefix and one key at most: an empty list or another key is
// "no", and a refused list is an error, never "no".
func TestExists(t *testing.T) {
	t.Parallel()
	const key = "media/v1/e1/master.m3u8"
	tests := []struct {
		name    string
		status  int
		listed  string
		want    bool
		wantErr error
	}{
		{"listed", http.StatusOK, key, true, nil},
		{"empty list", http.StatusOK, "", false, nil},
		{"only a longer key", http.StatusOK, key + ".tmp", false, nil},
		{"denied", http.StatusForbidden, "", false, ErrAccessDenied},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var query url.Values
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/media" && r.URL.Path != "/media/" {
					t.Errorf("path %s, want the media bucket", r.URL.Path)
				}
				query = r.URL.Query()
				w.Header().Set("Content-Type", "application/xml")
				w.WriteHeader(tt.status)
				if tt.status != http.StatusOK {
					_, _ = w.Write([]byte(`<Error><Code>AccessDenied</Code></Error>`))
					return
				}
				body := `<ListBucketResult><Name>media</Name><KeyCount>0</KeyCount><MaxKeys>1</MaxKeys><IsTruncated>false</IsTruncated>`
				if tt.listed != "" {
					body = `<ListBucketResult><Name>media</Name><KeyCount>1</KeyCount><MaxKeys>1</MaxKeys><IsTruncated>false</IsTruncated>` +
						`<Contents><Key>` + tt.listed + `</Key><Size>7</Size></Contents>`
				}
				_, _ = w.Write([]byte(body + `</ListBucketResult>`))
			}))
			defer srv.Close()
			got, err := newTestStore(t, testConfig(srv.URL)).Exists(t.Context(), key)
			if got != tt.want || !errors.Is(err, tt.wantErr) || (tt.wantErr == nil) != (err == nil) {
				t.Errorf("Exists() = %v, %v; want %v, %v", got, err, tt.want, tt.wantErr)
			}
			if query.Get("list-type") != "2" || query.Get("prefix") != key || query.Get("max-keys") != "1" {
				t.Errorf("query = %v, want list-type=2, prefix=%s, max-keys=1", query, key)
			}
		})
	}
}

// List pages through every key under the prefix of the right bucket, in key order; a prefix
// without the trailing "/" or outside the contract is refused before any request.
func TestList(t *testing.T) {
	t.Parallel()
	const prefix = "media/v1/e1/a1/"
	pages := [][]string{{prefix + "index_360p.m3u8", prefix + "index_360p_00001.ts"}, {prefix + "thumb.0000000.jpg"}}
	var queries []url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/media" && r.URL.Path != "/media/" {
			t.Errorf("path %s, want the media bucket", r.URL.Path)
		}
		q := r.URL.Query()
		queries = append(queries, q)
		page := 0
		if q.Get("continuation-token") == "next" {
			page = 1
		}
		var b strings.Builder
		fmt.Fprintf(&b, `<ListBucketResult><Name>media</Name><KeyCount>%d</KeyCount><IsTruncated>%t</IsTruncated>`,
			len(pages[page]), page == 0)
		if page == 0 {
			b.WriteString(`<NextContinuationToken>next</NextContinuationToken>`)
		}
		for _, k := range pages[page] {
			fmt.Fprintf(&b, `<Contents><Key>%s</Key><Size>1</Size></Contents>`, k)
		}
		w.Header().Set("Content-Type", "application/xml")
		_, _ = w.Write([]byte(b.String() + `</ListBucketResult>`))
	}))
	defer srv.Close()
	s := newTestStore(t, testConfig(srv.URL))

	keys, err := s.List(t.Context(), prefix)
	if err != nil {
		t.Fatal(err)
	}
	if want := append(slices.Clone(pages[0]), pages[1]...); !slices.Equal(keys, want) {
		t.Errorf("List() = %v, want %v", keys, want)
	}
	if len(queries) != 2 || queries[0].Get("prefix") != prefix || queries[1].Get("prefix") != prefix {
		t.Errorf("queries = %v, want two pages of prefix %s", queries, prefix)
	}
	for _, p := range []string{"media/v1/e1/a1", "other/v1/", "media/", ""} {
		if _, err := s.List(t.Context(), p); !errors.Is(err, ErrInvalidKey) {
			t.Errorf("List(%q) error = %v, want ErrInvalidKey", p, err)
		}
	}
	if len(queries) != 2 {
		t.Errorf("refused prefixes sent %d requests", len(queries)-2)
	}
}

// Copy sends one CopyObject in the bucket of both keys that replaces the metadata with the given
// headers; keys in two buckets or outside the contract are refused before any request, and the
// errors are classified as for any other call.
func TestCopy(t *testing.T) {
	t.Parallel()
	type sent struct{ method, path, source, directive, contentType, cacheControl string }
	var got []sent
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, sent{r.Method, r.URL.Path, r.Header.Get("X-Amz-Copy-Source"),
			r.Header.Get("X-Amz-Metadata-Directive"), r.Header.Get("Content-Type"), r.Header.Get("Cache-Control")})
		w.Header().Set("Content-Type", "application/xml")
		if strings.HasSuffix(r.URL.Path, "/denied.ts") {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`<Error><Code>AccessDenied</Code></Error>`))
			return
		}
		_, _ = w.Write([]byte(`<CopyObjectResult><ETag>"e"</ETag></CopyObjectResult>`))
	}))
	defer srv.Close()
	s := newTestStore(t, testConfig(srv.URL))
	const immutable = "max-age=31536000, immutable"
	const dir = "media/v1/e1/a1/"

	if err := s.Copy(t.Context(), dir+"index_360p_00001.ts", dir+"index_360p_00001.ts", "video/mp2t", immutable); err != nil {
		t.Fatalf("Copy() in place: %v", err)
	}
	if err := s.Copy(t.Context(), dir+"thumb.0000000.jpg", dir+"thumbnail.jpg", "image/jpeg", immutable); err != nil {
		t.Fatalf("Copy() to another key: %v", err)
	}
	if err := s.Copy(t.Context(), dir+"denied.ts", dir+"denied.ts", "video/mp2t", immutable); !errors.Is(err, ErrAccessDenied) {
		t.Errorf("Copy() refused by storage: error = %v, want ErrAccessDenied", err)
	}
	for _, keys := range [][2]string{{"uploads/v1", dir + "x.ts"}, {dir + "x.ts", "uploads/v1"}, {"other/x", "other/x"}} {
		if err := s.Copy(t.Context(), keys[0], keys[1], "video/mp2t", immutable); !errors.Is(err, ErrInvalidKey) {
			t.Errorf("Copy(%q, %q) error = %v, want ErrInvalidKey", keys[0], keys[1], err)
		}
	}

	want := []sent{
		{http.MethodPut, "/media/" + dir + "index_360p_00001.ts", "media/" + dir + "index_360p_00001.ts", "REPLACE", "video/mp2t", immutable},
		{http.MethodPut, "/media/" + dir + "thumbnail.jpg", "media/" + dir + "thumb.0000000.jpg", "REPLACE", "image/jpeg", immutable},
		{http.MethodPut, "/media/" + dir + "denied.ts", "media/" + dir + "denied.ts", "REPLACE", "video/mp2t", immutable},
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("requests:\n%v\nwant\n%v", got, want)
	}
}

// A job record lives in the media bucket, outside media/, and Create writes it once.
func TestCreateJobRecord(t *testing.T) {
	t.Parallel()
	var paths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.Method+" "+r.URL.Path+" "+r.Header.Get("If-None-Match"))
	}))
	defer srv.Close()
	s := newTestStore(t, testConfig(srv.URL))
	f := filepath.Join(t.TempDir(), "record")
	if err := os.WriteFile(f, []byte(`{"reason":"TRANSCODE_FAILURE_REASON_SOURCE_MISSING"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.Create(t.Context(), "transcode-jobs/v1/e1.json", f, "application/json", ""); err != nil {
		t.Fatal(err)
	}
	if want := []string{"PUT /media/transcode-jobs/v1/e1.json *"}; !slices.Equal(paths, want) {
		t.Errorf("requests = %v, want %v", paths, want)
	}
}
