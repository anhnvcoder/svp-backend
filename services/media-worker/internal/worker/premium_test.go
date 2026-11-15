package worker

import (
	"errors"
	"slices"
	"strings"
	"testing"

	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/protobuf/proto"

	mediav1 "github.com/anhnvcoder/svp-backend/gen/go/svp/media/v1"
	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/transcode"
)

// withPremiumSource stores data as the source of a new premium video and returns its record.
func (e *env) withPremiumSource(t *testing.T, data []byte) (string, *kgo.Record) {
	t.Helper()
	id := ids.New()
	e.store.put(objstore.UploadsPrefix+id, data)
	return id, uploaded(t, id, len(data), func(_ *videov1.VideoEvent, up *videov1.VideoUploaded) { up.Premium = true })
}

// keys returns every stored key, sorted.
func (s *fakeStore) keys() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, 0, len(s.objects))
	for k := range s.objects {
		out = append(out, k)
	}
	slices.Sort(out)
	return out
}

// uris lists the URI lines of a playlist.
func uris(playlist []byte) []string {
	var out []string
	for line := range strings.SplitSeq(string(playlist), "\n") {
		if line = strings.TrimSpace(line); line != "" && !strings.HasPrefix(line, "#") {
			out = append(out, line)
		}
	}
	return out
}

// checkPremium checks the stored output of premium video id's version against c, the result
// published for it, and returns the attempt the preview master names. The lowest rendition has
// segments segments, of which the preview holds preview; nothing is stored under media/, and
// preview/ holds nothing but segments, thumbnails and playlists of the lowest rendition.
func (e *env) checkPremium(t *testing.T, c *mediav1.TranscodeCompleted, id, version string, segments, preview int) string {
	t.Helper()
	prefix, pre := "premium/"+id+"/"+version+"/", "preview/"+id+"/"+version+"/"
	full, err := transcode.ParseMaster(e.store.get(prefix + transcode.MasterPlaylist))
	if err != nil {
		t.Fatalf("full master: %v", err)
	}
	pm, err := transcode.ParseMaster(e.store.get(pre + transcode.MasterPlaylist))
	if err != nil {
		t.Fatalf("preview master: %v", err)
	}
	lowest := full.Renditions[0].Name
	if len(pm.Renditions) != 1 || pm.Renditions[0] != full.Renditions[0] {
		t.Errorf("preview master names %+v, want only %+v", pm.Renditions, full.Renditions[0])
	}
	if c.GetVideoId() != id || c.GetPlaylistKey() != prefix+transcode.MasterPlaylist ||
		c.GetPreviewPlaylistKey() != pre+transcode.MasterPlaylist || c.GetThumbnailKey() != pre+pm.Attempt+"/"+transcode.Thumbnail {
		t.Errorf("completed = %v, want playlist %smaster.m3u8, preview %smaster.m3u8, thumbnail %s%s/thumbnail.jpg",
			c, prefix, pre, pre, pm.Attempt)
	}
	if !objstore.IsKeyUnder(objstore.PremiumPrefix, c.GetPlaylistKey(), id) ||
		!objstore.IsKeyUnder(objstore.PreviewPrefix, c.GetThumbnailKey(), id) ||
		!objstore.IsKeyUnder(objstore.PreviewPrefix, c.GetPreviewPlaylistKey(), id) {
		t.Errorf("completed %v has a key outside its prefix", c)
	}
	for _, k := range e.store.keys() {
		rest, inPreview := strings.CutPrefix(k, pre)
		_, name, _ := strings.Cut(rest, "/")
		switch {
		case strings.HasPrefix(k, objstore.MediaPrefix):
			t.Errorf("premium video stored %s", k)
		case !inPreview || rest == transcode.MasterPlaylist:
		case name != transcode.Thumbnail && name != transcode.PlaylistName(lowest) &&
			(!strings.HasPrefix(name, "index_"+lowest+"_") || !strings.HasSuffix(name, ".ts")):
			t.Errorf("preview holds %s, not of rendition %s", k, lowest)
		}
		if strings.HasPrefix(k, prefix) || inPreview {
			if cc := e.store.caches[k]; cc != CacheControl {
				t.Errorf("%s Cache-Control %q", k, cc)
			}
			if typ, _ := transcode.ContentType(k); e.store.types[k] != typ {
				t.Errorf("%s Content-Type %q, want %q", k, e.store.types[k], typ)
			}
		}
	}
	all := uris(e.store.get(prefix + pm.Attempt + "/" + transcode.PlaylistName(lowest)))
	playlist := e.store.get(pre + pm.Attempt + "/" + transcode.PlaylistName(lowest))
	got := uris(playlist)
	if len(all) != segments || !slices.Equal(got, all[:min(preview, len(all))]) {
		t.Errorf("rendition %s has %d segments, preview %v; want %d and the first %d", lowest, len(all), got, segments, preview)
	}
	if !strings.HasSuffix(string(playlist), "#EXT-X-ENDLIST\n") {
		t.Errorf("preview playlist has no #EXT-X-ENDLIST:\n%s", playlist)
	}
	for _, seg := range got {
		if data := e.store.get(pre + pm.Attempt + "/" + seg); data == nil || !slices.Equal(data, e.store.get(prefix+pm.Attempt+"/"+seg)) {
			t.Errorf("preview segment %s is not a copy of the premium one", seg)
		}
	}
	if e.store.get(pre+pm.Attempt+"/"+transcode.Thumbnail) == nil {
		t.Errorf("no preview thumbnail")
	}
	return pm.Attempt
}

// checkPremiumOrder checks the writes of one try that published premium video id's version: the
// segments before any playlist, the preview's segments, thumbnail, playlist and master in that
// order, and the full master last.
func checkPremiumOrder(t *testing.T, writes []string, id, version string) {
	t.Helper()
	prefix, pre := "premium/"+id+"/"+version+"/", "preview/"+id+"/"+version+"/"
	if len(writes) == 0 || writes[len(writes)-1] != prefix+transcode.MasterPlaylist {
		t.Fatalf("writes %v: want %smaster.m3u8 last", writes, prefix)
	}
	last := func(match func(string) bool) int {
		k := -1
		for i, w := range writes {
			if match(w) {
				k = i
			}
		}
		return k
	}
	first := func(match func(string) bool) int { return slices.IndexFunc(writes, match) }
	under := func(p, suffix string) func(string) bool {
		return func(k string) bool { return strings.HasPrefix(k, p) && strings.HasSuffix(k, suffix) }
	}
	steps := []int{
		last(under(prefix, ".ts")), first(under("", ".m3u8")),
		last(under(pre, ".ts")), first(under(pre, ".jpg")),
		first(under(pre, ".m3u8")), slices.Index(writes, pre+transcode.MasterPlaylist), len(writes) - 1,
	}
	if slices.Contains(steps, -1) || !slices.IsSorted(steps) || steps[0] == steps[1] {
		t.Errorf("writes %v out of order (positions %v)", writes, steps)
	}
}

// A premium video goes under premium/, never media/, with a public preview of its lowest
// rendition's first segments under preview/; a redelivery reads both back and writes nothing.
func TestHandlePremiumWritesPreview(t *testing.T) {
	t.Parallel()
	requireFFmpeg(t)
	for _, c := range []struct {
		name              string
		size              string
		seconds           int
		segments, preview int
		renditions        int
	}{
		{"two renditions, 2 segments", "1280x720", 8, 2, 1, 2},
		{"4 segments", "640x360", 16, 4, 2, 1},
		{"6 segments", "640x360", 24, 6, 3, 1},
		{"source rendition", "320x240", 8, 2, 1, 1},
	} {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			e := newEnv(t)
			id, r := e.withPremiumSource(t, clip(t, c.size, c.seconds))
			version := versionOf(t, r)
			e.handle(t, r)
			first, downloads := e.store.snapshot()
			checkPremiumOrder(t, first, id, version)

			e.handle(t, r)
			all, after := e.store.snapshot()
			if len(all) != len(first) {
				t.Errorf("redelivery wrote %v", all[len(first):])
			}
			// The master, the lowest rendition's playlist and the preview master.
			if after-downloads != 3 {
				t.Errorf("redelivery downloaded %d objects, want 3", after-downloads)
			}
			outs := e.read(t, OutputTopic, 2)
			c1, c2 := completedOf(t, outs[0], id), completedOf(t, outs[1], id)
			if len(c1.GetRenditions()) != c.renditions {
				t.Errorf("renditions = %v, want %d", renditionsOf(c1), c.renditions)
			}
			if c.size == "320x240" && c1.GetRenditions()[0].GetName() != "source" {
				t.Errorf("renditions = %v, want source", renditionsOf(c1))
			}
			attempt := e.checkPremium(t, c1, id, version, c.segments, c.preview)
			if got := e.attemptOf(t, "premium/"+id+"/"+version+"/"); got != attempt {
				t.Errorf("preview master names %s, full master %s: want the same try", attempt, got)
			}
			if !proto.Equal(c1, c2) {
				t.Errorf("redelivery gave another result:\n%v\n%v", c1, c2)
			}
			e.requireCleanWorkDir(t)
		})
	}
}

// A premium video of one segment has no preview that is not the whole video: it fails at once
// with PREVIEW_TOO_SHORT, and nothing is stored.
func TestHandlePremiumOneSegmentIsPreviewTooShort(t *testing.T) {
	t.Parallel()
	requireFFmpeg(t)
	e := newEnv(t)
	_, r := e.withPremiumSource(t, clip(t, "1280x720", 2))
	if f := e.failure(t, r); f.GetReason() != mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_PREVIEW_TOO_SHORT {
		t.Errorf("failed = %v, want PREVIEW_TOO_SHORT", f)
	}
	if uploads, _ := e.store.snapshot(); len(uploads) != 0 {
		t.Errorf("uploads = %v, want none", uploads)
	}
	e.requireCleanWorkDir(t)
}

// A copy into the preview that fails fails the try like any write, publishing nothing; the next
// try writes a new directory and its preview and master both name it.
func TestHandlePremiumFailedCopyRetriesInNewDirectory(t *testing.T) {
	t.Parallel()
	requireFFmpeg(t)
	e := newEnv(t)
	id, r := e.withPremiumSource(t, clip(t, "1280x720", 8))
	version := versionOf(t, r)
	var failed bool
	e.store.beforeUpload = func(key string) error {
		if strings.HasPrefix(key, objstore.PreviewPrefix) && strings.HasSuffix(key, ".ts") && !failed {
			failed = true
			return errors.New("objstore: copy: 503 Service Unavailable")
		}
		return nil
	}
	if err := e.w.Handle(t.Context(), r, kafkax.Attempt{Number: 1}); err == nil {
		t.Fatal("Handle succeeded with a failed copy")
	}
	partial, _ := e.store.snapshot()
	for _, k := range partial {
		if strings.HasPrefix(k, "preview/") || strings.HasSuffix(k, "/"+version+"/"+transcode.MasterPlaylist) {
			t.Errorf("failed try wrote %s", k)
		}
	}
	if n := e.count(t, OutputTopic); n != 0 {
		t.Fatalf("%d events published after the failed try", n)
	}

	e.handle(t, r)
	all, _ := e.store.snapshot()
	checkPremiumOrder(t, all[len(partial):], id, version)
	attempt := e.checkPremium(t, completedOf(t, e.read(t, OutputTopic, 2)[1], id), id, version, 2, 1)
	if strings.HasPrefix(partial[0], "premium/"+id+"/"+version+"/"+attempt+"/") {
		t.Errorf("the masters name %s, the directory of the failed try", attempt)
	}
	if got := e.attemptOf(t, "premium/"+id+"/"+version+"/"); got != attempt {
		t.Errorf("full master names %s, preview master %s", got, attempt)
	}
}

// A try that created the preview master and died before the full master: the next try keeps
// that preview master as it is, creates the full master naming its own directory, and publishes
// the thumbnail of the preview it kept; a redelivery publishes the same.
func TestHandlePremiumKeepsEarlierPreviewMaster(t *testing.T) {
	t.Parallel()
	requireFFmpeg(t)
	e := newEnv(t)
	id, r := e.withPremiumSource(t, clip(t, "1280x720", 8))
	version := versionOf(t, r)
	prefix, pre := "premium/"+id+"/"+version+"/", "preview/"+id+"/"+version+"/"
	var failed bool
	e.store.beforeUpload = func(key string) error {
		if key == prefix+transcode.MasterPlaylist && !failed {
			failed = true
			return errors.New("objstore: upload: 503 Service Unavailable")
		}
		return nil
	}
	if err := e.w.Handle(t.Context(), r, kafkax.Attempt{Number: 1}); err == nil {
		t.Fatal("Handle succeeded with a failed master")
	}
	kept := e.store.get(pre + transcode.MasterPlaylist)
	if kept == nil || e.store.get(prefix+transcode.MasterPlaylist) != nil {
		t.Fatalf("after the failed try: preview master %q, full master %q; want only the preview one",
			kept, e.store.get(prefix+transcode.MasterPlaylist))
	}

	e.handle(t, r)
	e.handle(t, r)
	if got := e.store.get(pre + transcode.MasterPlaylist); !slices.Equal(got, kept) {
		t.Errorf("preview master changed:\n%s\nwas\n%s", got, kept)
	}
	outs := e.read(t, OutputTopic, 2)
	c1, c2 := completedOf(t, outs[0], id), completedOf(t, outs[1], id)
	previewAttempt := e.checkPremium(t, c1, id, version, 2, 1)
	if full := e.attemptOf(t, prefix); full == previewAttempt {
		t.Errorf("full master names %s, the failed try's directory", full)
	}
	if !proto.Equal(c1, c2) {
		t.Errorf("redelivery gave another result:\n%v\n%v", c1, c2)
	}
}
