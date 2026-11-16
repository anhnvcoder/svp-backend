package hls

import (
	"errors"
	"strings"
	"testing"
)

const (
	attempt  = "0190a6e4-7b2c-7d3e-9f40-0000000000b2"
	attempt2 = "0190a6e4-7b2c-7d3e-9f40-0000000000b3"
)

var ladder = []string{"360p", "720p", "1080p", "source"}

// master is what media-worker writes (transcode.BuildMaster), with a comment line added.
const master = "#EXTM3U\n#EXT-X-VERSION:3\n" +
	"#EXT-X-STREAM-INF:BANDWIDTH=984000,RESOLUTION=640x360\n" + attempt + "/index_360p.m3u8\n" +
	"# a comment\n" +
	"#EXT-X-STREAM-INF:BANDWIDTH=2803000,RESOLUTION=1280x720\n" + attempt + "/index_720p.m3u8\n" +
	"#EXT-X-STREAM-INF:BANDWIDTH=5478000,RESOLUTION=1920x1080\n" + attempt + "/index_1080p.m3u8\n"

func allow(names ...string) func(string) bool {
	return func(r string) bool {
		for _, n := range names {
			if n == r {
				return true
			}
		}
		return false
	}
}

func TestParseMasterAndFilter(t *testing.T) {
	t.Parallel()
	m, err := ParseMaster([]byte(master), ladder)
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Variants) != 3 {
		t.Fatalf("Variants = %+v, want three", m.Variants)
	}
	v, ok := m.Variant("720p")
	if !ok || v != (Variant{Rendition: "720p", Attempt: attempt, URI: attempt + "/index_720p.m3u8"}) {
		t.Errorf("Variant(720p) = %+v, %v", v, ok)
	}
	if _, ok := m.Variant("source"); ok {
		t.Error("Variant(source) found in a master without it")
	}

	tests := []struct {
		name    string
		allowed []string
		want    string
	}{
		{"sd", []string{"source", "360p"}, "#EXTM3U\n#EXT-X-VERSION:3\n" +
			"#EXT-X-STREAM-INF:BANDWIDTH=984000,RESOLUTION=640x360\n360p.m3u8\n# a comment\n"},
		{"hd", []string{"source", "360p", "720p"}, "#EXTM3U\n#EXT-X-VERSION:3\n" +
			"#EXT-X-STREAM-INF:BANDWIDTH=984000,RESOLUTION=640x360\n360p.m3u8\n# a comment\n" +
			"#EXT-X-STREAM-INF:BANDWIDTH=2803000,RESOLUTION=1280x720\n720p.m3u8\n"},
		{"fhd", ladder, "#EXTM3U\n#EXT-X-VERSION:3\n" +
			"#EXT-X-STREAM-INF:BANDWIDTH=984000,RESOLUTION=640x360\n360p.m3u8\n# a comment\n" +
			"#EXT-X-STREAM-INF:BANDWIDTH=2803000,RESOLUTION=1280x720\n720p.m3u8\n" +
			"#EXT-X-STREAM-INF:BANDWIDTH=5478000,RESOLUTION=1920x1080\n1080p.m3u8\n"},
		{"only the top", []string{"1080p"}, "#EXTM3U\n#EXT-X-VERSION:3\n# a comment\n" +
			"#EXT-X-STREAM-INF:BANDWIDTH=5478000,RESOLUTION=1920x1080\n1080p.m3u8\n"},
	}
	for _, tt := range tests {
		got, err := m.Filter(allow(tt.allowed...))
		if err != nil || string(got) != tt.want {
			t.Errorf("%s: Filter() = %q, %v\nwant %q", tt.name, got, err, tt.want)
		}
	}
	if got, err := m.Filter(allow("source")); !errors.Is(err, ErrNoVariant) || got != nil {
		t.Errorf("Filter() with no variant allowed = %q, %v; want ErrNoVariant", got, err)
	}
	// Filtering leaves the master as it was for the next call.
	if again, _ := m.Filter(allow(ladder...)); string(again) != tests[2].want {
		t.Errorf("second Filter() = %q", again)
	}
}

func TestParseMasterCRLF(t *testing.T) {
	t.Parallel()
	m, err := ParseMaster([]byte(strings.ReplaceAll(master, "\n", "\r\n")), ladder)
	if err != nil || len(m.Variants) != 3 {
		t.Fatalf("ParseMaster() of CRLF lines = %+v, %v", m, err)
	}
}

// Anything but the form media-worker writes is refused, never passed on.
func TestParseMasterRejects(t *testing.T) {
	t.Parallel()
	inf := "#EXT-X-STREAM-INF:BANDWIDTH=984000,RESOLUTION=640x360\n"
	head := "#EXTM3U\n#EXT-X-VERSION:3\n"
	tests := []struct{ name, data string }{
		{"rendition outside the ladder", head + inf + attempt + "/index_480p.m3u8\n"},
		{"3600p", head + inf + attempt + "/index_3600p.m3u8\n"},
		{"no attempt", head + inf + "index_360p.m3u8\n"},
		{"no index_ base", head + inf + attempt + "/360p.m3u8\n"},
		{"not a playlist", head + inf + attempt + "/index_360p.ts\n"},
		{"two directories", head + inf + attempt + "/x/index_360p.m3u8\n"},
		{"climbs out", head + inf + "../" + attempt + "/index_360p.m3u8\n"},
		{"attempt not a UUID", head + inf + "a1/index_360p.m3u8\n"},
		{"attempt in upper case", head + inf + strings.ToUpper(attempt) + "/index_360p.m3u8\n"},
		{"absolute URI", head + inf + "https://evil.example/" + attempt + "/index_360p.m3u8\n"},
		{"two attempts", head + inf + attempt + "/index_360p.m3u8\n" + inf + attempt2 + "/index_720p.m3u8\n"},
		{"rendition twice", head + inf + attempt + "/index_360p.m3u8\n" + inf + attempt + "/index_360p.m3u8\n"},
		{"URI without a variant tag", head + attempt + "/index_360p.m3u8\n"},
		{"variant tag at the end", head + inf},
		{"variant tag before a tag", head + inf + "#EXT-X-VERSION:3\n" + attempt + "/index_360p.m3u8\n"},
		{"variant tag before a blank", head + inf + "\n" + attempt + "/index_360p.m3u8\n"},
		{"audio rendition", head + `#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="en",URI="` + attempt + `/audio.m3u8"` + "\n" + inf + attempt + "/index_360p.m3u8\n"},
		{"i-frame playlist", head + `#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1,URI="` + attempt + `/iframe.m3u8"` + "\n" + inf + attempt + "/index_360p.m3u8\n"},
		{"session key", head + `#EXT-X-SESSION-KEY:METHOD=AES-128,URI="https://k.example/k"` + "\n" + inf + attempt + "/index_360p.m3u8\n"},
		{"no header", "#EXT-X-VERSION:3\n" + inf + attempt + "/index_360p.m3u8\n"},
		{"empty", ""},
		{"no variant", head},
		{"media playlist", "#EXTM3U\n#EXTINF:4.0,\nindex_360p_000.ts\n#EXT-X-ENDLIST\n"},
	}
	for _, tt := range tests {
		if m, err := ParseMaster([]byte(tt.data), ladder); !errors.Is(err, ErrMalformed) || m != nil {
			t.Errorf("%s: ParseMaster() = %+v, %v; want ErrMalformed", tt.name, m, err)
		}
	}
}

// media is a VOD playlist as ffmpeg writes it; MediaConvert numbers segments from 00001.
const media = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n" +
	"#EXTINF:4.000000,\nindex_360p_000.ts\n#EXTINF:4.000000,\nindex_360p_001.ts\n#EXTINF:1.5,\nindex_360p_00002.ts\n" +
	"#EXT-X-ENDLIST\n"

func fakeSign(uri string) (string, error) {
	return "https://media.svp.example/premium/v/e/a/" + uri + "?Policy=p&Signature=s", nil
}

func TestSignMedia(t *testing.T) {
	t.Parallel()
	got, err := SignMedia([]byte(media), "360p", fakeSign)
	if err != nil {
		t.Fatal(err)
	}
	const base = "https://media.svp.example/premium/v/e/a/"
	want := "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n" +
		"#EXTINF:4.000000,\n" + base + "index_360p_000.ts?Policy=p&Signature=s\n" +
		"#EXTINF:4.000000,\n" + base + "index_360p_001.ts?Policy=p&Signature=s\n" +
		"#EXTINF:1.5,\n" + base + "index_360p_00002.ts?Policy=p&Signature=s\n#EXT-X-ENDLIST\n"
	if string(got) != want {
		t.Errorf("SignMedia() = %q\nwant %q", got, want)
	}

	var signed []string
	if _, err := SignMedia([]byte(strings.ReplaceAll(media, "\n", "\r\n")), "360p", func(uri string) (string, error) {
		signed = append(signed, uri)
		return uri, nil
	}); err != nil || strings.Join(signed, " ") != "index_360p_000.ts index_360p_001.ts index_360p_00002.ts" {
		t.Errorf("CRLF playlist: signed %v, %v", signed, err)
	}
}

// Only segments of the rendition asked for, in the playlist's own directory, are signed; any
// other URI or a tag that brings in another object fails the whole playlist.
func TestSignMediaRejects(t *testing.T) {
	t.Parallel()
	head := "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\n"
	tests := []struct{ name, data string }{
		{"another rendition", head + "index_720p_000.ts\n"},
		{"3600p", head + "index_3600p_000.ts\n"},
		{"36p", "#EXTM3U\n#EXTINF:4.0,\nindex_36p_000.ts\n"},
		{"no number", head + "index_360p_.ts\n"},
		{"not a number", head + "index_360p_00a.ts\n"},
		{"no base", head + "000.ts\n"},
		{"not a segment", head + "index_360p_000.m3u8\n"},
		{"another directory", head + "x/index_360p_000.ts\n"},
		{"climbs out", head + "../index_360p_000.ts\n"},
		{"encoded climb", head + "%2e%2e/index_360p_000.ts\n"},
		{"absolute URI", head + "https://evil.example/index_360p_000.ts\n"},
		{"query", head + "index_360p_000.ts?x=1\n"},
		{"init section", "#EXTM3U\n" + `#EXT-X-MAP:URI="init.mp4"` + "\n#EXTINF:4.0,\nindex_360p_000.ts\n"},
		{"key", "#EXTM3U\n" + `#EXT-X-KEY:METHOD=AES-128,URI="https://k.example/k"` + "\n#EXTINF:4.0,\nindex_360p_000.ts\n"},
		{"key method none", "#EXTM3U\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:4.0,\nindex_360p_000.ts\n"},
		{"partial segment", "#EXTM3U\n" + `#EXT-X-PART:DURATION=1,URI="index_360p_000.0.ts"` + "\n#EXTINF:4.0,\nindex_360p_000.ts\n"},
		{"no header", "#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nindex_360p_000.ts\n"},
		{"no segment", "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-ENDLIST\n"},
		{"empty", ""},
	}
	for _, tt := range tests {
		got, err := SignMedia([]byte(tt.data), "360p", fakeSign)
		if !errors.Is(err, ErrMalformed) || got != nil {
			t.Errorf("%s: SignMedia() = %q, %v; want ErrMalformed", tt.name, got, err)
		}
	}
}

func TestSignMediaErrors(t *testing.T) {
	t.Parallel()
	boom := errors.New("boom")
	got, err := SignMedia([]byte(media), "360p", func(string) (string, error) { return "", boom })
	if !errors.Is(err, boom) || errors.Is(err, ErrMalformed) || got != nil {
		t.Errorf("SignMedia() with a failing signer = %q, %v; want the signer's error", got, err)
	}
	for _, r := range []string{"", "360P", "360p_", "../360p", "*"} {
		if got, err := SignMedia([]byte(media), r, fakeSign); err == nil || got != nil {
			t.Errorf("SignMedia(rendition %q) = %q, %v; want an error", r, got, err)
		}
	}
}
