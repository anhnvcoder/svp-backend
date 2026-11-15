package transcode

import (
	"errors"
	"fmt"
	"strings"
)

// PreviewMaxSegments caps the public preview of a premium video: 12 s at SegmentSeconds.
const PreviewMaxSegments = 3

// ErrPreviewTooShort means the lowest rendition of a premium video has too few segments for a
// preview that is not the whole video (reason PREVIEW_TOO_SHORT).
var ErrPreviewTooShort = errors.New("transcode: too short for a preview")

// Preview is the public preview cut from the playlist of a premium video's lowest rendition.
type Preview struct {
	// Playlist is the VOD playlist of Segments, ended by #EXT-X-ENDLIST.
	Playlist []byte
	// Segments are the file names of the first segments of the rendition, in playlist order:
	// min(PreviewMaxSegments, n/2) of its n segments, so a preview is at most half of its segments.
	Segments []string
}

// CutPreview returns the Preview of a rendition playlist written by this package's layout: every
// URI a segment file name next to the playlist, no tag carrying a URI. A playlist of one segment
// fails with ErrPreviewTooShort; one in another shape is an error, since the preview must not
// name anything but the segments copied for it.
func CutPreview(playlist []byte) (Preview, error) {
	lines := strings.Split(strings.ReplaceAll(string(playlist), "\r\n", "\n"), "\n")
	var n int
	for _, line := range lines {
		line = strings.TrimSpace(line)
		switch {
		case strings.Contains(line, "URI="):
			return Preview{}, fmt.Errorf("transcode: preview: tag with a URI: %q", line)
		case line == "" || strings.HasPrefix(line, "#"):
		case strings.Contains(line, "/") || !strings.HasSuffix(line, ".ts"):
			return Preview{}, fmt.Errorf("transcode: preview: %q is not a segment next to the playlist", line)
		default:
			n++
		}
	}
	keep := min(PreviewMaxSegments, n/2)
	if keep == 0 {
		return Preview{}, fmt.Errorf("%w: the lowest rendition has %d segment(s)", ErrPreviewTooShort, n)
	}
	var b strings.Builder
	var p Preview
	// The header and every tag up to the last segment kept; the tags of later segments go.
	for _, line := range lines {
		line = strings.TrimSpace(line)
		switch {
		case line == "" || line == "#EXT-X-ENDLIST":
			continue
		case !strings.HasPrefix(line, "#"):
			p.Segments = append(p.Segments, line)
		}
		b.WriteString(line + "\n")
		if len(p.Segments) == keep {
			break
		}
	}
	b.WriteString("#EXT-X-ENDLIST\n")
	p.Playlist = []byte(b.String())
	return p, nil
}
