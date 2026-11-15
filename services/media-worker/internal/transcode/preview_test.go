package transcode

import (
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
)

// mediaPlaylist is a VOD playlist of n 4-second segments of 360p, as ffmpeg writes it.
func mediaPlaylist(n int) string {
	var b strings.Builder
	b.WriteString("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n")
	for i := range n {
		fmt.Fprintf(&b, "#EXTINF:4.000000,\nindex_360p_%03d.ts\n", i)
	}
	b.WriteString("#EXT-X-ENDLIST\n")
	return b.String()
}

// The preview keeps min(3, n/2) segments: never more than half of the video, never more than
// 12 s, and none at all for a video of one segment.
func TestCutPreviewSegmentCount(t *testing.T) {
	t.Parallel()
	for _, c := range []struct{ n, want int }{{2, 1}, {3, 1}, {4, 2}, {5, 2}, {6, 3}, {7, 3}, {15, 3}} {
		t.Run(fmt.Sprint(c.n), func(t *testing.T) {
			t.Parallel()
			p, err := CutPreview([]byte(mediaPlaylist(c.n)))
			if err != nil {
				t.Fatal(err)
			}
			var want []string
			for i := range c.want {
				want = append(want, fmt.Sprintf("index_360p_%03d.ts", i))
			}
			if !slices.Equal(p.Segments, want) {
				t.Errorf("segments = %v, want %v", p.Segments, want)
			}
			text := string(p.Playlist)
			if got := segmentLines(text); !slices.Equal(got, want) {
				t.Errorf("playlist URIs = %v, want %v:\n%s", got, want, text)
			}
			if !strings.HasPrefix(text, "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n") ||
				!strings.HasSuffix(text, "\n#EXT-X-ENDLIST\n") || strings.Count(text, "#EXT-X-ENDLIST") != 1 {
				t.Errorf("playlist lacks the header or one final #EXT-X-ENDLIST:\n%s", text)
			}
			if got := strings.Count(text, "#EXTINF:"); got != c.want {
				t.Errorf("%d #EXTINF, want %d", got, c.want)
			}
			if d, err := PlaylistDuration(p.Playlist); err != nil || d.Seconds() != float64(4*c.want) {
				t.Errorf("PlaylistDuration = %v, %v; want %d s", d, err, 4*c.want)
			}
		})
	}
}

func segmentLines(playlist string) []string {
	var out []string
	for line := range strings.SplitSeq(playlist, "\n") {
		if line != "" && !strings.HasPrefix(line, "#") {
			out = append(out, line)
		}
	}
	return out
}

func TestCutPreviewTooShort(t *testing.T) {
	t.Parallel()
	for _, n := range []int{0, 1} {
		if _, err := CutPreview([]byte(mediaPlaylist(n))); !errors.Is(err, ErrPreviewTooShort) {
			t.Errorf("%d segments: err = %v, want ErrPreviewTooShort", n, err)
		}
	}
}

func TestCutPreviewCRLF(t *testing.T) {
	t.Parallel()
	p, err := CutPreview([]byte(strings.ReplaceAll(mediaPlaylist(4), "\n", "\r\n")))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(p.Playlist), "\r") || !slices.Equal(p.Segments, []string{"index_360p_000.ts", "index_360p_001.ts"}) {
		t.Errorf("preview = %q, %v", p.Playlist, p.Segments)
	}
}

// A playlist naming anything but segments next to it is refused, even past the segments kept:
// the preview would name an object nobody copied, or one outside preview/.
func TestCutPreviewRefusesOtherShapes(t *testing.T) {
	t.Parallel()
	for name, edit := range map[string]func(string) string{
		"path":   func(s string) string { return strings.Replace(s, "index_360p_005.ts", "../index_360p_005.ts", 1) },
		"url":    func(s string) string { return strings.Replace(s, "index_360p_000.ts", "https://x.example/a.ts", 1) },
		"not ts": func(s string) string { return strings.Replace(s, "index_360p_001.ts", "index_360p_001.mp4", 1) },
		"map tag": func(s string) string {
			return strings.Replace(s, "#EXT-X-PLAYLIST-TYPE:VOD", `#EXT-X-MAP:URI="init.mp4"`, 1)
		},
		"key tag": func(s string) string {
			return strings.Replace(s, "#EXT-X-ENDLIST", `#EXT-X-KEY:METHOD=AES-128,URI="k"`, 1)
		},
		"nested dir": func(s string) string { return strings.Replace(s, "index_360p_002.ts", "720p/index_720p_002.ts", 1) },
	} {
		if _, err := CutPreview([]byte(edit(mediaPlaylist(6)))); err == nil || errors.Is(err, ErrPreviewTooShort) {
			t.Errorf("%s: err = %v, want a refusal", name, err)
		}
	}
}
