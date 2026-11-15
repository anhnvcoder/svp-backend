package server

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/url"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"go.opentelemetry.io/otel/attribute"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/mediasign"
	"github.com/anhnvcoder/svp-backend/internal/secret"
)

const (
	methodGetPlaybackPlaylist = "/svp.video.v1.VideoService/GetPlaybackPlaylist"
	testMediaBaseURL          = "https://media.svp.example"
	testSigningKeyID          = "K2JCJMDEHXQW5F"
)

// playbackNow is the clock of the signers. The expiry of a video of 83.25 s is the frame after
// now + 83.25 s + 5 min, 1_800_001_800; without a length it is 1_800_000_900.
var playbackNow = time.Unix(1_800_000_550, 0)

const (
	wantExpiry           = 1_800_001_800
	wantExpiryNoDuration = 1_800_000_900
	// wantS3TTL is wantExpiry - playbackNow.
	wantS3TTL = 1250 * time.Second
)

// The variants of the master media-worker writes (transcode.BuildMaster), by rendition.
var streamInf = map[string]string{
	"source": "#EXT-X-STREAM-INF:BANDWIDTH=984000,RESOLUTION=480x270",
	"360p":   "#EXT-X-STREAM-INF:BANDWIDTH=984000,RESOLUTION=640x360",
	"720p":   "#EXT-X-STREAM-INF:BANDWIDTH=2803000,RESOLUTION=1280x720",
	"1080p":  "#EXT-X-STREAM-INF:BANDWIDTH=5478000,RESOLUTION=1920x1080",
}

// storedMaster is the master playlist of renditions as stored under premium/.
func storedMaster(renditions ...string) string {
	out := "#EXTM3U\n#EXT-X-VERSION:3\n"
	for _, r := range renditions {
		out += streamInf[r] + "\n" + testAttempt + "/index_" + r + ".m3u8\n"
	}
	return out
}

// filteredMaster is the master GetPlaybackPlaylist returns with only renditions.
func filteredMaster(renditions ...string) string {
	out := "#EXTM3U\n#EXT-X-VERSION:3\n"
	for _, r := range renditions {
		out += streamInf[r] + "\n" + r + ".m3u8\n"
	}
	return out
}

// mediaPlaylistTags are the lines of every media playlist before its segments.
const mediaPlaylistTags = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"

// storedMedia is the media playlist of rendition with two segments.
func storedMedia(rendition string) string {
	return mediaPlaylistTags + "#EXTINF:4.000000,\nindex_" + rendition + "_00000.ts\n" +
		"#EXTINF:4.000000,\nindex_" + rendition + "_00001.ts\n#EXT-X-ENDLIST\n"
}

func mediaKeyOf(id, rendition string) string {
	return "premium/" + id + "/" + testVersion + "/" + testAttempt + "/index_" + rendition + ".m3u8"
}

// testSigningKey is generated once: RSA 2048 takes a while.
var testSigningKey = sync.OnceValue(func() *rsa.PrivateKey {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	return key
})

func cloudFrontConfig(t *testing.T) mediasign.Config {
	t.Helper()
	der, err := x509.MarshalPKCS8PrivateKey(testSigningKey())
	if err != nil {
		t.Fatal(err)
	}
	return mediasign.Config{
		Signer:  mediasign.SignerCloudFront,
		BaseURL: testMediaBaseURL,
		KeyID:   testSigningKeyID,
		Key:     secret.New(string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))),
	}
}

// newPlaybackServer returns a Server on the test database signing with cfg on the clock
// playbackNow, its fake storage and its logs.
func newPlaybackServer(t *testing.T, cfg mediasign.Config) (*Server, *fakeStorage, *logBuffer) {
	t.Helper()
	s, storage, logs := newServerWithStorage()
	signer, err := mediasign.New(cfg, storage, func() time.Time { return playbackNow })
	if err != nil {
		t.Fatal(err)
	}
	s.signer = signer
	return s, storage, logs
}

// storePremium stores a READY premium video of author with the playlists of renditions.
func storePremium(t *testing.T, storage *fakeStorage, author string, renditions ...string) string {
	t.Helper()
	id := insertPremium(t, author, "READY")
	storage.putFile(premiumPlaylistKeyOf(id), storedMaster(renditions...))
	for _, r := range renditions {
		storage.putFile(mediaKeyOf(id, r), storedMedia(r))
	}
	return id
}

// viewerWith returns a user holding tier on video id.
func viewerWith(t *testing.T, s *Server, id string, tier videov1.Tier) string {
	t.Helper()
	user := ids.New()
	if _, err := grantEntitlement(t, s, user, id, tier); err != nil {
		t.Fatal(err)
	}
	return user
}

func playback(t *testing.T, s *Server, caller, videoID, rendition string) (string, error) {
	t.Helper()
	resp, err := call(t.Context(), caller, methodGetPlaybackPlaylist,
		&videov1.GetPlaybackPlaylistRequest{VideoId: videoID, Rendition: rendition}, s.GetPlaybackPlaylist)
	return resp.GetContent(), err
}

// wantNoSignature fails when the logs hold any part of a signed URL.
func wantNoSignature(t *testing.T, logs *logBuffer) {
	t.Helper()
	for _, part := range []string{"Signature=", "Policy=", "Key-Pair-Id", "X-Amz-"} {
		if strings.Contains(logs.String(), part) {
			t.Errorf("logs contain %q: %s", part, logs.String())
		}
	}
}

// The master keeps the variants of the caller's tier, in order, with URIs on the playback route.
func TestPlaybackMasterKeepsTheRenditionsOfTheTier(t *testing.T) {
	needDB(t)
	s, storage, _ := newPlaybackServer(t, cloudFrontConfig(t))
	author := ids.New()
	id := storePremium(t, storage, author, "360p", "720p", "1080p")
	for _, tc := range []struct {
		name   string
		caller string
		want   string
	}{
		{"author", author, filteredMaster("360p", "720p", "1080p")},
		{"sd", viewerWith(t, s, id, videov1.Tier_TIER_SD), filteredMaster("360p")},
		{"hd", viewerWith(t, s, id, videov1.Tier_TIER_HD), filteredMaster("360p", "720p")},
		{"fhd", viewerWith(t, s, id, videov1.Tier_TIER_FHD), filteredMaster("360p", "720p", "1080p")},
	} {
		got, err := playback(t, s, tc.caller, id, "")
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if got != tc.want {
			t.Errorf("%s: master =\n%s\nwant\n%s", tc.name, got, tc.want)
		}
	}

	// A source smaller than the lowest step has the source rendition only, which SD plays.
	small := storePremium(t, storage, author, "source")
	got, err := playback(t, s, viewerWith(t, s, small, videov1.Tier_TIER_SD), small, "")
	if err != nil || got != filteredMaster("source") {
		t.Errorf("sd on a source-only master = %q, %v; want %q", got, err, filteredMaster("source"))
	}
}

// Without an entitlement nothing is read or signed, whatever the rendition asked for.
func TestPlaybackWithoutEntitlement(t *testing.T) {
	needDB(t)
	s, storage, _ := newPlaybackServer(t, cloudFrontConfig(t))
	id := storePremium(t, storage, ids.New(), "360p", "720p")
	// An entitlement to another video opens nothing here.
	other := storePremium(t, storage, ids.New(), "360p")
	stranger := viewerWith(t, s, other, videov1.Tier_TIER_FHD)
	reads := storage.readCalls()
	for _, rendition := range []string{"", "360p", "480p"} {
		_, err := playback(t, s, stranger, id, rendition)
		wantError(t, err, codes.PermissionDenied, ReasonNotEntitled)
	}
	if got := storage.readCalls(); got != reads {
		t.Errorf("storage read %d times for a caller without entitlement, want 0", got-reads)
	}
}

func TestPlaybackRegularVideoIsNotPremium(t *testing.T) {
	needDB(t)
	s, _, _ := newPlaybackServer(t, cloudFrontConfig(t))
	author, id := ids.New(), ids.New()
	insertVideo(t, id, author, "READY", true, time.Now(), time.Now())
	for _, rendition := range []string{"", "360p"} {
		_, err := playback(t, s, author, id, rendition)
		wantError(t, err, codes.FailedPrecondition, ReasonVideoNotPremium)
	}
}

// A missing video and one not READY look the same, to the author too; a malformed id is refused.
func TestPlaybackVideoNotFound(t *testing.T) {
	needDB(t)
	s, _, _ := newPlaybackServer(t, cloudFrontConfig(t))
	author := ids.New()
	processing := insertPremium(t, author, "PROCESSING")
	for _, id := range []string{ids.New(), processing} {
		_, err := playback(t, s, author, id, "")
		wantError(t, err, codes.NotFound, ReasonVideoNotFound)
	}
	_, err := playback(t, s, author, "not-a-uuid", "")
	wantError(t, err, codes.InvalidArgument, ReasonInvalidVideoID)
	_, err = playback(t, s, "", processing, "")
	if status.Code(err) != codes.Unauthenticated {
		t.Errorf("without a caller: error = %v, want UNAUTHENTICATED", err)
	}
}

// A rendition above the tier is refused; one the video does not have is not found.
func TestPlaybackRenditionOutsideTheTier(t *testing.T) {
	needDB(t)
	s, storage, _ := newPlaybackServer(t, cloudFrontConfig(t))
	author := ids.New()
	id := storePremium(t, storage, author, "360p", "720p")
	sd := viewerWith(t, s, id, videov1.Tier_TIER_SD)
	_, err := playback(t, s, sd, id, "720p")
	wantError(t, err, codes.PermissionDenied, ReasonRenditionNotEntitled)
	for _, rendition := range []string{"1080p", "480p", "master", "../720p", "720P"} {
		_, err := playback(t, s, author, id, rendition)
		wantError(t, err, codes.NotFound, ReasonRenditionNotFound)
	}
	if _, err := playback(t, s, sd, id, "360p"); err != nil {
		t.Errorf("sd 360p: %v", err)
	}
}

// cfPolicy is the custom policy of a CloudFront signed URL.
type cfPolicy struct {
	Statement []struct {
		Resource  string
		Condition struct {
			DateLessThan struct {
				EpochTime int64 `json:"AWS:EpochTime"`
			}
		}
	}
}

// cfDecode reverses the base64 of CloudFront URLs.
func cfDecode(t *testing.T, s string) []byte {
	t.Helper()
	b, err := base64.StdEncoding.DecodeString(strings.NewReplacer("-", "+", "_", "=", "~", "/").Replace(s))
	if err != nil {
		t.Fatalf("decode %q: %v", s, err)
	}
	return b
}

// signedSegments checks that playlist is storedMedia(rendition) with each segment replaced by an
// absolute URL under prefix, and returns the query of each.
func signedSegments(t *testing.T, playlist, rendition, prefix string) []string {
	t.Helper()
	lines := strings.Split(playlist, "\n")
	want := strings.Split(storedMedia(rendition), "\n")
	if len(lines) != len(want) {
		t.Fatalf("playlist =\n%s\nwant the lines of\n%s", playlist, storedMedia(rendition))
	}
	var queries []string
	for i, line := range lines {
		if strings.HasPrefix(want[i], "#") || want[i] == "" {
			if line != want[i] {
				t.Errorf("line %d = %q, want %q", i+1, line, want[i])
			}
			continue
		}
		u, query, ok := strings.Cut(line, "?")
		if !ok || u != prefix+want[i] {
			t.Fatalf("segment line %d = %q, want %s%s?<signature>", i+1, line, prefix, want[i])
		}
		queries = append(queries, query)
	}
	return queries
}

// The cloudfront signer signs one policy for the rendition's segments, up to the expiry frame.
func TestPlaybackCloudFrontSignsTheRendition(t *testing.T) {
	needDB(t)
	s, storage, logs := newPlaybackServer(t, cloudFrontConfig(t))
	id := storePremium(t, storage, ids.New(), "360p", "720p")
	hd := viewerWith(t, s, id, videov1.Tier_TIER_HD)
	got, err := playback(t, s, hd, id, "720p")
	if err != nil {
		t.Fatal(err)
	}
	dir := "/premium/" + id + "/" + testVersion + "/" + testAttempt + "/"
	queries := signedSegments(t, got, "720p", testMediaBaseURL+dir)
	if len(queries) != 2 || queries[0] != queries[1] {
		t.Fatalf("queries = %q, want one query shared by both segments", queries)
	}
	q, err := url.ParseQuery(queries[0])
	if err != nil {
		t.Fatal(err)
	}
	if len(q) != 4 || q.Get("Key-Pair-Id") != testSigningKeyID || q.Get("Hash-Algorithm") != "SHA256" {
		t.Errorf("query = %v, want Policy, Signature, Key-Pair-Id=%s and Hash-Algorithm=SHA256", q, testSigningKeyID)
	}
	policy := cfDecode(t, q.Get("Policy"))
	digest := sha256.Sum256(policy)
	if err := rsa.VerifyPKCS1v15(&testSigningKey().PublicKey, crypto.SHA256, digest[:], cfDecode(t, q.Get("Signature"))); err != nil {
		t.Errorf("signature does not verify: %v", err)
	}
	var p cfPolicy
	if err := json.Unmarshal(policy, &p); err != nil || len(p.Statement) != 1 {
		t.Fatalf("policy %s: %v", policy, err)
	}
	if want := testMediaBaseURL + dir + "index_720p_*"; p.Statement[0].Resource != want {
		t.Errorf("Resource = %q, want %q", p.Statement[0].Resource, want)
	}
	if got := p.Statement[0].Condition.DateLessThan.EpochTime; got != wantExpiry {
		t.Errorf("EpochTime = %d, want %d", got, wantExpiry)
	}
	wantNoSignature(t, logs)
}

// A READY premium video without a length still gets the margin of the expiry.
func TestPlaybackExpiryWithoutDuration(t *testing.T) {
	needDB(t)
	s, storage, _ := newPlaybackServer(t, cloudFrontConfig(t))
	author := ids.New()
	id := storePremium(t, storage, author, "360p")
	if _, err := testPool.Exec(t.Context(), "UPDATE videos SET duration_ms = NULL WHERE id = $1", id); err != nil {
		t.Fatal(err)
	}
	got, err := playback(t, s, author, id, "360p")
	if err != nil {
		t.Fatal(err)
	}
	queries := signedSegments(t, got, "360p", testMediaBaseURL+"/premium/"+id+"/"+testVersion+"/"+testAttempt+"/")
	q, err := url.ParseQuery(queries[0])
	if err != nil {
		t.Fatal(err)
	}
	var p cfPolicy
	if err := json.Unmarshal(cfDecode(t, q.Get("Policy")), &p); err != nil {
		t.Fatal(err)
	}
	if got := p.Statement[0].Condition.DateLessThan.EpochTime; got != wantExpiryNoDuration {
		t.Errorf("EpochTime = %d, want %d", got, wantExpiryNoDuration)
	}
}

// The s3 signer presigns each segment on the public endpoint until the expiry.
func TestPlaybackS3PresignsEachSegment(t *testing.T) {
	needDB(t)
	s, storage, logs := newPlaybackServer(t, mediasign.Config{Signer: mediasign.SignerS3})
	id := storePremium(t, storage, ids.New(), "360p")
	sd := viewerWith(t, s, id, videov1.Tier_TIER_SD)
	got, err := playback(t, s, sd, id, "360p")
	if err != nil {
		t.Fatal(err)
	}
	queries := signedSegments(t, got, "360p", fakePublicEndpoint+"/media/premium/"+id+"/"+testVersion+"/"+testAttempt+"/")
	for _, query := range queries {
		q, err := url.ParseQuery(query)
		if err != nil {
			t.Fatal(err)
		}
		if q.Get("X-Amz-Expires") != "1250" || q.Get("X-Amz-Signature") == "" {
			t.Errorf("query = %v, want a SigV4 presign expiring in 1250 s", q)
		}
	}
	if ttls := storage.presignTTLs(); !slices.Equal(ttls, []time.Duration{wantS3TTL, wantS3TTL}) {
		t.Errorf("PresignGet ttls = %v, want %v for each of the two segments", ttls, wantS3TTL)
	}
	wantNoSignature(t, logs)
}

// A playlist not in the form media-worker writes is never passed on, and nothing signed is logged.
func TestPlaybackMalformedPlaylistIsInternal(t *testing.T) {
	needDB(t)
	for _, tc := range []struct {
		name, master, media, logged string
	}{
		{"unknown URI in master", storedMaster("360p") + "https://elsewhere.example/index_360p.m3u8\n", "", "parse master playlist"},
		{"URI tag in master", storedMaster("360p") + "#EXT-X-MEDIA:TYPE=AUDIO,URI=\"a.m3u8\"\n", "", "parse master playlist"},
		{"segment of another directory", storedMaster("360p"),
			storedMedia("360p") + "#EXTINF:4.0,\n../" + testAttempt + "/index_360p_00002.ts\n", "sign media playlist"},
		{"absolute segment", storedMaster("360p"),
			storedMedia("360p") + "#EXTINF:4.0,\nhttps://elsewhere.example/x.ts\n", "sign media playlist"},
		{"key tag", storedMaster("360p"),
			mediaPlaylistTags + "#EXT-X-KEY:METHOD=NONE\n#EXTINF:4.0,\nindex_360p_00000.ts\n", "sign media playlist"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, storage, logs := newPlaybackServer(t, cloudFrontConfig(t))
			author := ids.New()
			id := insertPremium(t, author, "READY")
			storage.putFile(premiumPlaylistKeyOf(id), tc.master)
			storage.putFile(mediaKeyOf(id, "360p"), tc.media)
			_, err := playback(t, s, author, id, "360p")
			if status.Code(err) != codes.Internal || status.Convert(err).Message() != "internal error" {
				t.Fatalf("error = %v, want INTERNAL with message %q", err, "internal error")
			}
			if len(logs.records(t, tc.logged)) != 1 {
				t.Errorf("logs = %s, want one %q record", logs.String(), tc.logged)
			}
			wantNoSignature(t, logs)
		})
	}
}

// A storage failure that may pass is UNAVAILABLE and not cached; a playlist read once is cached.
func TestPlaybackStorageFailures(t *testing.T) {
	needDB(t)
	s, storage, _ := newPlaybackServer(t, cloudFrontConfig(t))
	author := ids.New()
	id := storePremium(t, storage, author, "360p")

	storage.setReadErr(errors.New("objstore: read: connection refused"))
	_, err := playback(t, s, author, id, "")
	wantError(t, err, codes.Unavailable, ReasonDependencyUnavailable)
	storage.setReadErr(nil)
	if got, err := playback(t, s, author, id, ""); err != nil || got != filteredMaster("360p") {
		t.Fatalf("after storage recovered: %q, %v", got, err)
	}
	if _, err := playback(t, s, author, id, "360p"); err != nil {
		t.Fatal(err)
	}
	reads := storage.readCalls()
	for _, rendition := range []string{"", "360p"} {
		if _, err := playback(t, s, author, id, rendition); err != nil {
			t.Fatal(err)
		}
	}
	if got := storage.readCalls(); got != reads {
		t.Errorf("storage read %d more times for cached playlists, want 0", got-reads)
	}

	// A READY video whose playlist is missing cannot be fixed by retrying.
	missing := insertPremium(t, author, "READY")
	storage.putFile(premiumPlaylistKeyOf(missing), storedMaster("360p"))
	_, err = playback(t, s, author, missing, "360p")
	if status.Code(err) != codes.Internal {
		t.Errorf("missing media playlist: error = %v, want INTERNAL", err)
	}
}

func TestPlaylistCacheIsBounded(t *testing.T) {
	t.Parallel()
	c := newPlaylistCache(2, 10)
	c.add("a", []byte("aaa"))
	c.add("b", []byte("bbb"))
	c.get("a")
	c.add("c", []byte("ccc"))
	if _, ok := c.get("b"); ok {
		t.Error("b kept: the least recently used entry goes first when the entries are full")
	}
	c.add("d", []byte("dddddddd"))
	for _, key := range []string{"a", "c"} {
		if _, ok := c.get(key); ok {
			t.Errorf("%s kept past the byte bound", key)
		}
	}
	c.add("big", []byte("01234567890"))
	if _, ok := c.get("big"); ok {
		t.Error("a playlist over the byte bound is cached")
	}
	if got, ok := c.get("d"); !ok || string(got) != "dddddddd" {
		t.Errorf("d = %q, %v", got, ok)
	}
}

// playlistCounts returns the svp.video.playback.playlists points by kind/result.
func playlistCounts(t *testing.T, reader *sdkmetric.ManualReader) map[string]int64 {
	t.Helper()
	var data metricdata.ResourceMetrics
	if err := reader.Collect(t.Context(), &data); err != nil {
		t.Fatal(err)
	}
	out := map[string]int64{}
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			if m.Name != "svp.video.playback.playlists" {
				continue
			}
			for _, p := range m.Data.(metricdata.Sum[int64]).DataPoints {
				kind, _ := p.Attributes.Value(attribute.Key("kind"))
				result, _ := p.Attributes.Value(attribute.Key("result"))
				if p.Attributes.Len() != 2 {
					t.Errorf("attributes = %v, want kind and result", p.Attributes)
				}
				out[kind.AsString()+"/"+result.AsString()] = p.Value
			}
		}
	}
	return out
}

func TestPlaybackMetric(t *testing.T) {
	needDB(t)
	_, reader := testTelemetry(t)
	s, storage, _ := newPlaybackServer(t, cloudFrontConfig(t))
	author := ids.New()
	id := storePremium(t, storage, author, "360p", "720p")
	sd := viewerWith(t, s, id, videov1.Tier_TIER_SD)
	regular := ids.New()
	insertVideo(t, regular, author, "READY", true, time.Now(), time.Now())

	_, _ = playback(t, s, author, id, "")
	_, _ = playback(t, s, sd, id, "360p")
	_, _ = playback(t, s, sd, id, "720p")
	_, _ = playback(t, s, ids.New(), id, "")
	_, _ = playback(t, s, author, ids.New(), "360p")
	_, _ = playback(t, s, author, id, "480p")
	// Not counted: a regular video and a malformed id.
	_, _ = playback(t, s, author, regular, "")
	_, _ = playback(t, s, author, "not-a-uuid", "")

	want := map[string]int64{
		"master/ok": 1, "media/ok": 1, "media/rendition_not_entitled": 1, "master/not_entitled": 1,
		"media/not_found": 2,
	}
	got := playlistCounts(t, reader)
	if len(got) != len(want) {
		t.Errorf("counts = %v, want %v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %d, want %d (all: %v)", k, got[k], v, got)
		}
	}
}
