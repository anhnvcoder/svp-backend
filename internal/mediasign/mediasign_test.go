package mediasign

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/anhnvcoder/svp-backend/internal/secret"
)

const (
	video1  = "0190a6e4-7b2c-7d3e-9f40-000000000001"
	video2  = "0190a6e4-7b2c-7d3e-9f40-000000000002"
	version = "0190a6e4-7b2c-7d3e-9f40-0000000000a1"
	attempt = "0190a6e4-7b2c-7d3e-9f40-0000000000b2"
	baseURL = "https://media.svp.example"
	keyID   = "K2JCJMDEHXQW5F"
)

// testKey is one RSA 2048 key for the whole package: generating it takes a noticeable moment.
var testKey = sync.OnceValue(func() *rsa.PrivateKey {
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	return k
})

func pkcs8PEM(t *testing.T, key any) string {
	t.Helper()
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
}

func fixedClock(t time.Time) func() time.Time { return func() time.Time { return t } }

func rendition(videoID, name string) Rendition {
	return Rendition{VideoID: videoID, Version: version, Attempt: attempt, Name: name}
}

func cloudFront(t *testing.T, now time.Time) Signer {
	t.Helper()
	s, err := New(Config{Signer: SignerCloudFront, BaseURL: baseURL, KeyID: keyID, Key: secret.New(pkcs8PEM(t, testKey()))},
		nil, fixedClock(now))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// The expiry is the first multiple of 900 s at or after now + length + 5 min: a sum already on a
// multiple stays there, anything past it, by a nanosecond or more, goes to the next one.
func TestExpiry(t *testing.T) {
	t.Parallel()
	const frame = 1_800_000_000 // a multiple of 900
	onFrame := time.Unix(frame, 0)
	tests := []struct {
		name   string
		now    time.Time
		length time.Duration
		want   int64
	}{
		{"sum on a frame", onFrame.Add(-5*time.Minute - 3*time.Minute), 3 * time.Minute, frame},
		{"sum a nanosecond past", onFrame.Add(-5*time.Minute - 3*time.Minute + time.Nanosecond), 3 * time.Minute, frame + 900},
		{"sum a second past", onFrame.Add(-5 * time.Minute).Add(time.Second), 0, frame + 900},
		{"sum a second before", onFrame.Add(-5 * time.Minute).Add(-time.Second), 0, frame},
		{"sum just after the previous frame", onFrame.Add(-900*time.Second - 5*time.Minute + time.Second), 0, frame},
		{"long video", onFrame.Add(-5 * time.Minute).Add(-180 * time.Second), 180 * time.Second, frame},
		{"millisecond length", onFrame.Add(-5 * time.Minute), time.Millisecond, frame + 900},
	}
	for _, tt := range tests {
		got := Expiry(tt.now, tt.length)
		if got.Unix() != tt.want || got.Nanosecond() != 0 || got.Location() != time.UTC {
			t.Errorf("%s: Expiry(%v, %v) = %v, want Unix %d in UTC", tt.name, tt.now, tt.length, got, tt.want)
		}
		if lo, hi := tt.now.Add(tt.length+5*time.Minute), tt.now.Add(tt.length+20*time.Minute); got.Before(lo) || !got.Before(hi) {
			t.Errorf("%s: Expiry = %v, want in [%v, %v)", tt.name, got, lo, hi)
		}
	}
}

// unCFBase64 undoes the CloudFront URL base64.
func unCFBase64(t *testing.T, s string) []byte {
	t.Helper()
	if strings.ContainsAny(s, "+/=") {
		t.Errorf("%q holds a character CloudFront's URL base64 replaces", s)
	}
	b, err := base64.StdEncoding.DecodeString(strings.NewReplacer("-", "+", "_", "=", "~", "/").Replace(s))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// signedURL splits a CloudFront URL into the URL without query and the policy and signature it
// carries, checking the query holds exactly the four parameters, in order.
func signedURL(t *testing.T, raw string) (string, []byte, []byte) {
	t.Helper()
	plain, query, ok := strings.Cut(raw, "?")
	if !ok {
		t.Fatalf("%s has no query", raw)
	}
	parts := strings.Split(query, "&")
	names := []string{"Policy", "Signature", "Key-Pair-Id", "Hash-Algorithm"}
	if len(parts) != len(names) {
		t.Fatalf("query %s, want %v", query, names)
	}
	values := make([]string, len(parts))
	for i, p := range parts {
		k, v, _ := strings.Cut(p, "=")
		if k != names[i] {
			t.Fatalf("query parameter %d is %s, want %s", i, k, names[i])
		}
		values[i] = v
	}
	if values[2] != keyID || values[3] != "SHA256" {
		t.Errorf("Key-Pair-Id, Hash-Algorithm = %s, %s; want %s, SHA256", values[2], values[3], keyID)
	}
	return plain, unCFBase64(t, values[0]), unCFBase64(t, values[1])
}

// covers is how CloudFront matches a URL without its signing parameters against a resource whose
// only wildcard is a trailing "*".
func covers(resource, plainURL string) bool {
	return strings.HasPrefix(plainURL, strings.TrimSuffix(resource, "*"))
}

// The policy is the exact bytes of the custom policy, the signature verifies against it with the
// public key and RSA PKCS#1 v1.5 over SHA-256, and against nothing else.
func TestCloudFrontSignature(t *testing.T) {
	t.Parallel()
	now := time.Unix(1_800_000_000-600, 0)
	s := cloudFront(t, now)
	sign, err := s.Rendition(t.Context(), rendition(video1, "360p"), 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := sign("index_360p_00001.ts")
	if err != nil {
		t.Fatal(err)
	}
	plain, policy, sig := signedURL(t, raw)

	dir := "premium/" + video1 + "/" + version + "/" + attempt + "/"
	if want := baseURL + "/" + dir + "index_360p_00001.ts"; plain != want {
		t.Errorf("URL = %s, want %s", plain, want)
	}
	exp := Expiry(now, 30*time.Second).Unix()
	resource := baseURL + "/" + dir + "index_360p_*"
	want := `{"Statement":[{"Resource":"` + resource + `","Condition":{"DateLessThan":{"AWS:EpochTime":` +
		strconv.FormatInt(exp, 10) + `}}}]}`
	if string(policy) != want {
		t.Errorf("policy = %s\nwant     %s", policy, want)
	}
	if exp != 1_800_000_000 {
		t.Errorf("exp = %d, want the frame after now + 30 s + 5 min", exp)
	}
	digest := sha256.Sum256(policy)
	if err := rsa.VerifyPKCS1v15(&testKey().PublicKey, crypto.SHA256, digest[:], sig); err != nil {
		t.Errorf("signature does not verify with the public key: %v", err)
	}

	// The same signature does not verify for any other policy: another video, another rendition,
	// a later expiry.
	for _, other := range []string{
		strings.Replace(want, video1, video2, 1),
		strings.Replace(want, "index_360p_*", "index_720p_*", 1),
		strings.Replace(want, strconv.FormatInt(exp, 10), strconv.FormatInt(exp+900, 10), 1),
	} {
		d := sha256.Sum256([]byte(other))
		if rsa.VerifyPKCS1v15(&testKey().PublicKey, crypto.SHA256, d[:], sig) == nil {
			t.Errorf("signature verifies for %s", other)
		}
	}

	// Every segment of the rendition gets the same query, and a second call in the same frame
	// signs the same URL.
	_, query, _ := strings.Cut(raw, "?")
	raw2, err := sign("index_360p_00002.ts")
	if err != nil || !strings.HasSuffix(raw2, "/index_360p_00002.ts?"+query) {
		t.Errorf("second segment = %s, %v; want the same query", raw2, err)
	}
	again, err := cloudFront(t, now.Add(time.Minute)).Rendition(t.Context(), rendition(video1, "360p"), 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if raw3, _ := again("index_360p_00001.ts"); raw3 != raw {
		t.Errorf("a minute later in the same frame: %s, want %s", raw3, raw)
	}
}

func TestCFBase64(t *testing.T) {
	t.Parallel()
	in := base64.StdEncoding.EncodeToString([]byte{0xfb, 0xff})
	if in != "+/8=" {
		t.Fatalf("standard base64 = %s, want +/8=", in)
	}
	if got := cfBase64.Replace(in); got != "-~8_" {
		t.Errorf("cfBase64(%s) = %s, want -~8_", in, got)
	}
}

// A signature covers the segments of one rendition of one video: the resource of video 1 does not
// cover video 2, 360p covers neither 3600p nor 720p, and the SignFunc refuses to put the query on
// any of them.
func TestCloudFrontScope(t *testing.T) {
	t.Parallel()
	s := cloudFront(t, time.Unix(1_800_000_000, 0))
	sign, err := s.Rendition(t.Context(), rendition(video1, "360p"), time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := sign("index_360p_00001.ts")
	if err != nil {
		t.Fatal(err)
	}
	_, policy, _ := signedURL(t, raw)
	resource := strings.Split(strings.Split(string(policy), `"Resource":"`)[1], `"`)[0]

	dir1 := baseURL + "/premium/" + video1 + "/" + version + "/" + attempt + "/"
	dir2 := baseURL + "/premium/" + video2 + "/" + version + "/" + attempt + "/"
	for _, tt := range []struct {
		url  string
		want bool
	}{
		{dir1 + "index_360p_00001.ts", true},
		{dir1 + "index_360p_00042.ts", true},
		{dir2 + "index_360p_00001.ts", false},
		{dir1 + "index_3600p_00001.ts", false},
		{dir1 + "index_720p_00001.ts", false},
		{dir1 + "index_360p.m3u8", false},
		{baseURL + "/premium/" + video1 + "/" + version + "/master.m3u8", false},
		{baseURL + "/media/" + video1 + "/" + version + "/" + attempt + "/index_360p_00001.ts", false},
	} {
		if got := covers(resource, tt.url); got != tt.want {
			t.Errorf("resource %s covers %s = %v, want %v", resource, tt.url, got, tt.want)
		}
	}

	for _, seg := range []string{
		"index_3600p_00001.ts", "index_720p_00001.ts", "index_360p.m3u8", "../index_360p_00001.ts",
		"x/index_360p_00001.ts", "index_360p_%2e%2e", "index_360p_a/../../x", "index_360p_ a", "",
	} {
		if u, err := sign(seg); !errors.Is(err, ErrScope) || u != "" {
			t.Errorf("sign(%q) = %q, %v; want ErrScope", seg, u, err)
		}
	}
}

// A Rendition outside the layout is refused before anything is signed, by both signers.
func TestRenditionScope(t *testing.T) {
	t.Parallel()
	signers := map[string]Signer{
		SignerCloudFront: cloudFront(t, time.Unix(1_800_000_000, 0)),
		SignerS3:         &s3Signer{store: &fakePresigner{}, now: fixedClock(time.Unix(1_800_000_000, 0))},
	}
	bad := []Rendition{
		rendition("", "360p"),
		rendition("v1", "360p"),
		rendition(video1+"/x", "360p"),
		rendition("../"+video1, "360p"),
		rendition(strings.ToUpper(video1), "360p"),
		{VideoID: video1, Version: "", Attempt: attempt, Name: "360p"},
		{VideoID: video1, Version: version + "/..", Attempt: attempt, Name: "360p"},
		{VideoID: video1, Version: version, Attempt: "a", Name: "360p"},
		rendition(video1, ""),
		rendition(video1, "360P"),
		rendition(video1, "360p_"),
		rendition(video1, "360p/x"),
		rendition(video1, "*"),
	}
	for kind, s := range signers {
		for _, r := range bad {
			if f, err := s.Rendition(t.Context(), r, time.Minute); !errors.Is(err, ErrScope) || f != nil {
				t.Errorf("%s: Rendition(%+v) error = %v, want ErrScope", kind, r, err)
			}
		}
	}
}

type fakePresigner struct {
	keys []string
	ttls []time.Duration
	err  error
}

func (f *fakePresigner) PresignGet(_ context.Context, key string, ttl time.Duration) (string, error) {
	f.keys = append(f.keys, key)
	f.ttls = append(f.ttls, ttl)
	if f.err != nil {
		return "", f.err
	}
	return "http://127.0.0.1:9000/media/" + key + "?X-Amz-Expires=" + strconv.Itoa(int(ttl/time.Second)), nil
}

// The s3 signer presigns each segment's key for the time left until the expiry of the frame.
func TestS3Signer(t *testing.T) {
	t.Parallel()
	now := time.Unix(1_800_000_000-1000, 500)
	store := &fakePresigner{}
	s, err := New(Config{Signer: SignerS3}, store, fixedClock(now))
	if err != nil {
		t.Fatal(err)
	}
	sign, err := s.Rendition(t.Context(), rendition(video1, "720p"), 42*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	for _, seg := range []string{"index_720p_000.ts", "index_720p_001.ts"} {
		if _, err := sign(seg); err != nil {
			t.Fatalf("sign(%s): %v", seg, err)
		}
	}
	dir := "premium/" + video1 + "/" + version + "/" + attempt + "/"
	wantTTL := Expiry(now, 42*time.Second).Sub(now)
	if fmt.Sprint(store.keys) != fmt.Sprint([]string{dir + "index_720p_000.ts", dir + "index_720p_001.ts"}) {
		t.Errorf("presigned keys = %v", store.keys)
	}
	for _, ttl := range store.ttls {
		if ttl != wantTTL {
			t.Errorf("ttl = %v, want %v (exp - now)", ttl, wantTTL)
		}
	}
	if wantTTL != 1000*time.Second-500*time.Nanosecond {
		t.Errorf("ttl = %v, want the time left until the frame now + 42 s + 5 min falls in", wantTTL)
	}

	for _, seg := range []string{"index_7200p_000.ts", "index_360p_000.ts", "../index_720p_000.ts"} {
		if _, err := sign(seg); !errors.Is(err, ErrScope) {
			t.Errorf("sign(%q) error = %v, want ErrScope", seg, err)
		}
	}
	if len(store.keys) != 2 {
		t.Errorf("refused segments reached the store: %v", store.keys)
	}

	store.err = errors.New("boom")
	if _, err := sign("index_720p_002.ts"); !errors.Is(err, store.err) {
		t.Errorf("sign() error = %v, want the store's", err)
	}
}

func setEnv(t *testing.T, env map[string]string) {
	t.Helper()
	for _, name := range []string{"MEDIA_SIGNER", "MEDIA_SIGNED_BASE_URL", "MEDIA_SIGNING_KEY_ID", "MEDIA_SIGNING_KEY"} {
		t.Setenv(name, env[name])
	}
}

func TestReadEnv(t *testing.T) {
	goodKey := pkcs8PEM(t, testKey())
	cloudFrontEnv := func(edit func(map[string]string)) map[string]string {
		env := map[string]string{"MEDIA_SIGNER": "cloudfront", "MEDIA_SIGNED_BASE_URL": baseURL,
			"MEDIA_SIGNING_KEY_ID": keyID, "MEDIA_SIGNING_KEY": goodKey}
		if edit != nil {
			edit(env)
		}
		return env
	}

	setEnv(t, map[string]string{"MEDIA_SIGNER": "s3"})
	cfg, err := ReadEnv()
	if err != nil || cfg != (Config{Signer: SignerS3}) {
		t.Errorf("s3: ReadEnv() = %+v, %v", cfg, err)
	}

	setEnv(t, cloudFrontEnv(nil))
	cfg, err = ReadEnv()
	if err != nil || cfg.Signer != SignerCloudFront || cfg.BaseURL != baseURL || cfg.KeyID != keyID || cfg.Key.Reveal() != goodKey {
		t.Errorf("cloudfront: ReadEnv() = %+v, %v", cfg, err)
	}
	if printed := fmt.Sprintf("%v %+v %#v", cfg, cfg, cfg); strings.Contains(printed, "PRIVATE") {
		t.Errorf("printed config shows the key: %s", printed)
	}

	ecKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	// A key under the minimum, which ParsePrivateKey must refuse.
	smallKey, err := rsa.GenerateKey(rand.Reader, 1024) //nolint:gosec // deliberately weak test key
	if err != nil {
		t.Fatal(err)
	}
	pkcs1 := string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(testKey())}))
	pub, err := x509.MarshalPKIXPublicKey(&testKey().PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	pubPEM := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pub}))
	broken := strings.Replace(goodKey, goodKey[40:60], strings.Repeat("A", 20), 1)

	tests := []struct {
		name, variable string
		env            map[string]string
	}{
		{"no signer", "MEDIA_SIGNER", map[string]string{}},
		{"unknown signer", "MEDIA_SIGNER", map[string]string{"MEDIA_SIGNER": "S3"}},
		{"s3 with a base URL", "MEDIA_SIGNED_BASE_URL", map[string]string{"MEDIA_SIGNER": "s3", "MEDIA_SIGNED_BASE_URL": baseURL}},
		{"s3 with a key ID", "MEDIA_SIGNING_KEY_ID", map[string]string{"MEDIA_SIGNER": "s3", "MEDIA_SIGNING_KEY_ID": keyID}},
		{"s3 with a key", "MEDIA_SIGNING_KEY", map[string]string{"MEDIA_SIGNER": "s3", "MEDIA_SIGNING_KEY": goodKey}},
		{"no base URL", "MEDIA_SIGNED_BASE_URL", cloudFrontEnv(func(e map[string]string) { delete(e, "MEDIA_SIGNED_BASE_URL") })},
		{"no key ID", "MEDIA_SIGNING_KEY_ID", cloudFrontEnv(func(e map[string]string) { delete(e, "MEDIA_SIGNING_KEY_ID") })},
		{"no key", "MEDIA_SIGNING_KEY", cloudFrontEnv(func(e map[string]string) { delete(e, "MEDIA_SIGNING_KEY") })},
		{"http base URL", "MEDIA_SIGNED_BASE_URL", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNED_BASE_URL"] = "http://media.svp.example" })},
		{"base URL with a path", "MEDIA_SIGNED_BASE_URL", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNED_BASE_URL"] = baseURL + "/media" })},
		{"base URL with a trailing /", "MEDIA_SIGNED_BASE_URL", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNED_BASE_URL"] = baseURL + "/" })},
		{"base URL with a query", "MEDIA_SIGNED_BASE_URL", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNED_BASE_URL"] = baseURL + "?a=1" })},
		{"base URL with an empty query", "MEDIA_SIGNED_BASE_URL", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNED_BASE_URL"] = baseURL + "?" })},
		{"base URL with a fragment", "MEDIA_SIGNED_BASE_URL", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNED_BASE_URL"] = baseURL + "#x" })},
		{"base URL with a user", "MEDIA_SIGNED_BASE_URL", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNED_BASE_URL"] = "https://u@media.svp.example" })},
		{"base URL without a host", "MEDIA_SIGNED_BASE_URL", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNED_BASE_URL"] = "https://" })},
		{"key ID with a symbol", "MEDIA_SIGNING_KEY_ID", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNING_KEY_ID"] = "K2&x=1" })},
		{"key not PEM", "MEDIA_SIGNING_KEY", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNING_KEY"] = "not a key" })},
		{"key PKCS#1", "MEDIA_SIGNING_KEY", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNING_KEY"] = pkcs1 })},
		{"key not RSA", "MEDIA_SIGNING_KEY", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNING_KEY"] = pkcs8PEM(t, ecKey) })},
		{"key under 2048 bits", "MEDIA_SIGNING_KEY", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNING_KEY"] = pkcs8PEM(t, smallKey) })},
		{"public key", "MEDIA_SIGNING_KEY", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNING_KEY"] = pubPEM })},
		{"two keys", "MEDIA_SIGNING_KEY", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNING_KEY"] = goodKey + goodKey })},
		{"corrupt key", "MEDIA_SIGNING_KEY", cloudFrontEnv(func(e map[string]string) { e["MEDIA_SIGNING_KEY"] = broken })},
	}
	keyLines := strings.Split(goodKey+pkcs1+pkcs8PEM(t, smallKey), "\n")
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			setEnv(t, tt.env)
			cfg, err := ReadEnv()
			if err == nil {
				t.Fatalf("ReadEnv() = %+v, want an error", cfg)
			}
			if !strings.HasPrefix(err.Error(), tt.variable+" ") && !strings.Contains(err.Error(), " "+tt.variable+" ") {
				t.Errorf("error %q does not name %s", err, tt.variable)
			}
			for _, line := range keyLines {
				if len(line) > 16 && !strings.HasPrefix(line, "-----") && strings.Contains(err.Error(), line) {
					t.Errorf("error %q carries a line of a key", err)
				}
			}
			if cfg != (Config{}) {
				t.Errorf("ReadEnv() = %+v with an error, want the zero Config", cfg)
			}
		})
	}
}

func TestNewRejects(t *testing.T) {
	t.Parallel()
	good := Config{Signer: SignerCloudFront, BaseURL: baseURL, KeyID: keyID, Key: secret.New(pkcs8PEM(t, testKey()))}
	tests := []struct {
		name  string
		cfg   Config
		store Presigner
	}{
		{"no signer", Config{}, nil},
		{"s3 without a store", Config{Signer: SignerS3}, nil},
		{"bad base URL", func() Config { c := good; c.BaseURL = baseURL + "/x"; return c }(), nil},
		{"bad key ID", func() Config { c := good; c.KeyID = ""; return c }(), nil},
		{"bad key", func() Config { c := good; c.Key = secret.New("x"); return c }(), nil},
	}
	for _, tt := range tests {
		if s, err := New(tt.cfg, tt.store, time.Now); err == nil || s != nil {
			t.Errorf("%s: New() = %v, %v; want an error", tt.name, s, err)
		}
	}
	s, err := New(good, nil, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if printed := fmt.Sprintf("%v %+v", s, s); strings.Contains(printed, testKey().D.String()) {
		t.Error("printing the signer shows the private key")
	}
}
