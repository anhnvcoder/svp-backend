// Package hls reads the HLS playlists media-worker writes for a premium video and writes the ones
// a viewer gets: a master playlist keeping only the variants of the viewer's tier, and a media
// playlist whose segment URIs are signed URLs. A playlist in any other form is refused rather than
// passed on: a line this package does not know could point a player at an object nobody signed or
// checked.
//
// Design notes: docs/explanation/premium-playback.md
package hls

import (
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/anhnvcoder/svp-backend/internal/ids"
)

// ErrMalformed is returned for a playlist not in the form media-worker writes.
var ErrMalformed = errors.New("hls: playlist not in the form media-worker writes")

// ErrNoVariant is returned by Master.Filter when no variant of the master is allowed.
var ErrNoVariant = errors.New("hls: no variant allowed")

const (
	header = "#EXTM3U"
	// variantTag starts the line before the URI of each variant of a master playlist.
	variantTag = "#EXT-X-STREAM-INF:"
	// playlistBase and playlistExt make the name media-worker gives the playlist of a rendition,
	// index_<rendition>.m3u8; its segments are index_<rendition>_<number>.ts.
	playlistBase = "index_"
	playlistExt  = ".m3u8"
	segmentExt   = ".ts"
)

// RenditionURI is the URI of rendition in a filtered master: relative, so a player asks for it on
// the same route the master came from.
func RenditionURI(rendition string) string {
	return rendition + playlistExt
}

// Variant is one variant of a master playlist.
type Variant struct {
	// Rendition is the name in the variant's URI, such as 360p.
	Rendition string
	// Attempt is the directory of the variant's playlist and segments, a canonical UUID.
	Attempt string
	// URI is the variant's URI as stored, <Attempt>/index_<Rendition>.m3u8, relative to the master.
	URI string
}

// Master is a master playlist read by ParseMaster.
type Master struct {
	// Variants are in the order of the playlist.
	Variants []Variant
	lines    []string
	// uriLine maps the index of each URI line in lines to its variant.
	uriLine map[int]int
}

// ParseMaster reads a master playlist media-worker wrote: "#EXTM3U" first, then tags, each
// #EXT-X-STREAM-INF followed by the URI <attempt>/index_<rendition>.m3u8, with one attempt for
// every variant and each rendition in ladder at most once. A URI line anywhere else, a tag that
// carries a URI (#EXT-X-MEDIA, #EXT-X-I-FRAME-STREAM-INF, ...) or no variant at all is ErrMalformed.
func ParseMaster(data []byte, ladder []string) (*Master, error) {
	lines, err := splitLines(data)
	if err != nil {
		return nil, err
	}
	m := &Master{lines: lines, uriLine: map[int]int{}}
	for i := 1; i < len(lines); i++ {
		line := lines[i]
		switch {
		case line == "":
		case strings.HasPrefix(line, variantTag):
			if i+1 >= len(lines) || lines[i+1] == "" || strings.HasPrefix(lines[i+1], "#") {
				return nil, malformed(i, "#EXT-X-STREAM-INF without a URI on the next line")
			}
			i++
			v, err := parseVariantURI(lines[i], ladder)
			if err != nil {
				return nil, malformed(i, err.Error())
			}
			if len(m.Variants) > 0 && v.Attempt != m.Variants[0].Attempt {
				return nil, malformed(i, "variants under two attempts")
			}
			if _, dup := m.Variant(v.Rendition); dup {
				return nil, malformed(i, "rendition listed twice")
			}
			m.uriLine[i] = len(m.Variants)
			m.Variants = append(m.Variants, v)
		case strings.HasPrefix(line, "#"):
			if strings.Contains(line, "URI=") {
				return nil, malformed(i, "tag carrying a URI")
			}
		default:
			return nil, malformed(i, "URI without #EXT-X-STREAM-INF")
		}
	}
	if len(m.Variants) == 0 {
		return nil, fmt.Errorf("%w: no variant", ErrMalformed)
	}
	return m, nil
}

// parseVariantURI reads <attempt>/index_<rendition>.m3u8 with rendition in ladder.
func parseVariantURI(uri string, ladder []string) (Variant, error) {
	attempt, file, ok := strings.Cut(uri, "/")
	if !ok || strings.Contains(file, "/") {
		return Variant{}, errors.New("variant URI is not <attempt>/index_<rendition>.m3u8")
	}
	if _, err := ids.Parse(attempt); err != nil {
		return Variant{}, errors.New("variant attempt is not a canonical UUID")
	}
	name, hasBase := strings.CutPrefix(file, playlistBase)
	name, hasExt := strings.CutSuffix(name, playlistExt)
	if !hasBase || !hasExt || !slices.Contains(ladder, name) {
		return Variant{}, errors.New("variant playlist is not index_<rendition>.m3u8 of a rendition of the ladder")
	}
	return Variant{Rendition: name, Attempt: attempt, URI: uri}, nil
}

// Variant returns the variant of rendition, and false when the master has none.
func (m *Master) Variant(rendition string) (Variant, bool) {
	k := slices.IndexFunc(m.Variants, func(v Variant) bool { return v.Rendition == rendition })
	if k < 0 {
		return Variant{}, false
	}
	return m.Variants[k], true
}

// Filter returns the master with only the variants whose rendition allowed accepts, each URI
// replaced by RenditionURI, and every other line as it was, in order. No variant allowed is
// ErrNoVariant.
func (m *Master) Filter(allowed func(rendition string) bool) ([]byte, error) {
	out := make([]string, 0, len(m.lines))
	kept := 0
	for i, line := range m.lines {
		if strings.HasPrefix(line, variantTag) {
			// The URI follows on the next line; the tag goes with it.
			if !allowed(m.Variants[m.uriLine[i+1]].Rendition) {
				continue
			}
			out = append(out, line)
			continue
		}
		if k, isURI := m.uriLine[i]; isURI {
			if allowed(m.Variants[k].Rendition) {
				out = append(out, RenditionURI(m.Variants[k].Rendition))
				kept++
			}
			continue
		}
		out = append(out, line)
	}
	if kept == 0 {
		return nil, ErrNoVariant
	}
	return []byte(strings.Join(out, "\n")), nil
}

// SignMedia returns the media playlist of rendition in data with each segment URI replaced by
// sign(uri), and every tag as it was. Segment URIs must be index_<rendition>_<digits>.ts, in the
// playlist's directory; any other URI line, a tag that carries a URI (#EXT-X-MAP, #EXT-X-KEY, ...),
// an #EXT-X-KEY of any method or no segment at all is ErrMalformed. An error of sign is returned
// wrapped.
func SignMedia(data []byte, rendition string, sign func(uri string) (string, error)) ([]byte, error) {
	if rendition == "" || strings.ContainsFunc(rendition, func(c rune) bool { return (c < 'a' || c > 'z') && (c < '0' || c > '9') }) {
		return nil, errors.New("hls: rendition must be lowercase letters and digits")
	}
	lines, err := splitLines(data)
	if err != nil {
		return nil, err
	}
	segments := 0
	for i := 1; i < len(lines); i++ {
		line := lines[i]
		switch {
		case line == "":
		case strings.HasPrefix(line, "#EXT-X-MAP"), strings.HasPrefix(line, "#EXT-X-KEY"):
			return nil, malformed(i, "#EXT-X-MAP or #EXT-X-KEY")
		case strings.HasPrefix(line, "#"):
			if strings.Contains(line, "URI=") {
				return nil, malformed(i, "tag carrying a URI")
			}
		case !isSegment(line, rendition):
			return nil, malformed(i, "URI is not index_<rendition>_<number>.ts")
		default:
			signed, err := sign(line)
			if err != nil {
				return nil, fmt.Errorf("hls: sign the segment on line %d: %w", i+1, err)
			}
			lines[i] = signed
			segments++
		}
	}
	if segments == 0 {
		return nil, fmt.Errorf("%w: no segment", ErrMalformed)
	}
	return []byte(strings.Join(lines, "\n")), nil
}

// isSegment reports whether uri is index_<rendition>_<digits>.ts.
func isSegment(uri, rendition string) bool {
	n, hasBase := strings.CutPrefix(uri, playlistBase+rendition+"_")
	n, hasExt := strings.CutSuffix(n, segmentExt)
	if !hasBase || !hasExt || n == "" {
		return false
	}
	return !strings.ContainsFunc(n, func(c rune) bool { return c < '0' || c > '9' })
}

// splitLines splits a playlist into lines without "\r" or surrounding blanks, and checks that the
// first is the header.
func splitLines(data []byte) ([]string, error) {
	lines := strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n")
	for i := range lines {
		lines[i] = strings.TrimSpace(lines[i])
	}
	if lines[0] != header {
		return nil, malformed(0, "first line is not #EXTM3U")
	}
	return lines, nil
}

// malformed is ErrMalformed for the line at index i, named by its line number only: the line comes
// from storage and is not echoed into logs.
func malformed(i int, reason string) error {
	return fmt.Errorf("%w: line %d: %s", ErrMalformed, i+1, reason)
}
