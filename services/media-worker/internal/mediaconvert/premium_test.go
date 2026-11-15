package mediaconvert

import (
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/mediaconvert/types"
	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/durationpb"

	mediav1 "github.com/anhnvcoder/svp-backend/gen/go/svp/media/v1"
	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/transcode"
)

// premiumRecord is uploadedRecord of a premium video.
func premiumRecord(t *testing.T) (r *kgo.Record, id, version string) {
	t.Helper()
	r, id, version = uploadedRecord(t)
	var ev videov1.VideoEvent
	if err := proto.Unmarshal(r.Value, &ev); err != nil {
		t.Fatal(err)
	}
	ev.GetVideoUploaded().Premium = true
	value, err := proto.Marshal(&ev)
	if err != nil {
		t.Fatal(err)
	}
	r.Value = value
	return r, id, version
}

// premiumJob handles a premium video.uploaded and returns the job it created, its video and
// version, with the job's playlists holding segments of these lengths.
func (e *env) premiumJob(t *testing.T, segments []string) (job, id, version string) {
	t.Helper()
	e.mc.segments = segments
	r, id, version := premiumRecord(t)
	if err := e.handle(t, r); err != nil {
		t.Fatal(err)
	}
	jobs := e.mc.jobIDs()
	if len(jobs) != 1 {
		t.Fatalf("jobs %v, want one", jobs)
	}
	return jobs[0], id, version
}

// premiumCompleted is the transcode.completed of the reference clip as a premium video whose job
// ran as attempt, its 360p playlist of segments.
func premiumCompleted(id, version, attempt string, segments []string) *mediav1.TranscodeEvent {
	var total float64
	for _, s := range segments {
		var f float64
		_, _ = fmt.Sscan(s, &f)
		total += f
	}
	ev := completedFor(id, version, attempt)
	c := ev.GetTranscodeCompleted()
	c.PlaylistKey = "premium/" + id + "/" + version + "/master.m3u8"
	c.ThumbnailKey = "preview/" + id + "/" + version + "/" + attempt + "/thumbnail.jpg"
	c.PreviewPlaylistKey = "preview/" + id + "/" + version + "/master.m3u8"
	c.Duration = durationpb.New(time.Duration(total * float64(time.Second)).Round(time.Millisecond))
	return ev
}

func lengths(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = "4.000000"
	}
	return out
}

// A premium video's job writes under premium/ and says so in its metadata; once it completes,
// its preview, the first min(3, n/2) segments of 360p, goes under preview/ before both masters,
// and nothing of the video is under media/. A second COMPLETE writes nothing and publishes the
// same result.
func TestPremiumJobWritesPreview(t *testing.T) {
	t.Parallel()
	for _, c := range []struct{ segments, preview int }{{2, 1}, {4, 2}, {6, 3}} {
		t.Run(fmt.Sprint(c.segments), func(t *testing.T) {
			t.Parallel()
			e := newEnv(t)
			job, id, version := e.premiumJob(t, lengths(c.segments))
			prefix, pre := "premium/"+id+"/"+version+"/", "preview/"+id+"/"+version+"/"
			settings := e.mc.job(t, job)
			attempt := e.attemptOf(t, job)
			if settings.UserMetadata[metaPremium] != "true" {
				t.Errorf("job metadata %v, want premium true", settings.UserMetadata)
			}
			for _, g := range settings.Settings.OutputGroups {
				var dest string
				if s := g.OutputGroupSettings; s.HlsGroupSettings != nil {
					dest = aws.ToString(s.HlsGroupSettings.Destination)
				} else {
					dest = aws.ToString(s.FileGroupSettings.Destination)
				}
				if !strings.HasPrefix(dest, "s3://"+testMedia+"/"+prefix+attempt+"/") {
					t.Errorf("output group %s writes to %s, not under %s", aws.ToString(g.Name), dest, prefix)
				}
			}

			e.mc.complete(t, job)
			before := len(e.store.written())
			if !e.message(t, job, types.JobStatusComplete) {
				t.Fatal("COMPLETE message not done with")
			}
			writes := e.store.written()[before:]
			if !e.message(t, job, types.JobStatusComplete) {
				t.Fatal("second COMPLETE message not done with")
			}
			if again := e.store.written()[before+len(writes):]; len(again) != 0 {
				t.Errorf("second COMPLETE wrote %v", again)
			}
			sameResult(t, e.events(t), premiumCompleted(id, version, attempt, lengths(c.segments)))

			// Preview segments, thumbnail, playlist, preview master, then the full master last.
			want := []string{}
			for i := range c.preview {
				want = append(want, fmt.Sprintf("%s%s/index_360p_%05d.ts", pre, attempt, i+1))
			}
			want = append(want, pre+attempt+"/thumbnail.jpg", pre+attempt+"/index_360p.m3u8", pre+"master.m3u8", prefix+"master.m3u8")
			if got := writes[len(writes)-len(want):]; !slices.Equal(got, want) {
				t.Errorf("last writes %v, want %v", got, want)
			}
			if keys := e.store.keys(pre); !slices.Equal(keys, slices.Sorted(slices.Values(want[:len(want)-1]))) {
				t.Errorf("preview holds %v, want %v", keys, want[:len(want)-1])
			}
			if keys := e.store.keys(objstore.MediaPrefix); len(keys) != 0 {
				t.Errorf("premium video stored %v", keys)
			}
			playlist := string(e.store.get(pre + attempt + "/index_360p.m3u8"))
			if strings.Count(playlist, ".ts\n") != c.preview || !strings.HasSuffix(playlist, "\n#EXT-X-ENDLIST\n") {
				t.Errorf("preview playlist, want %d segments and #EXT-X-ENDLIST:\n%s", c.preview, playlist)
			}
			pm, err := transcode.ParseMaster(e.store.get(pre + "master.m3u8"))
			if err != nil || pm.Attempt != attempt || len(pm.Renditions) != 1 || pm.Renditions[0].Name != "360p" {
				t.Errorf("preview master = %+v, %v; want only 360p of %s", pm, err, attempt)
			}
			for _, k := range e.store.keys(pre) {
				if e.store.caches[k] != immutable {
					t.Errorf("%s Cache-Control %q", k, e.store.caches[k])
				}
				if name := strings.TrimPrefix(k, pre+attempt+"/"); strings.HasSuffix(k, ".ts") &&
					!slices.Equal(e.store.get(k), e.store.get(prefix+attempt+"/"+name)) {
					t.Errorf("%s is not a copy of the premium segment", k)
				}
			}
		})
	}
}

// A premium job whose lowest rendition has one segment fails with PREVIEW_TOO_SHORT, on every
// settle, with no master and nothing under preview/.
func TestPremiumOneSegmentIsPreviewTooShort(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	job, id, version := e.premiumJob(t, lengths(1))
	e.mc.complete(t, job)
	for range 2 {
		if !e.message(t, job, types.JobStatusComplete) {
			t.Fatal("COMPLETE message not done with")
		}
	}
	evs := e.events(t)
	sameResult(t, evs, failure(id, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_PREVIEW_TOO_SHORT,
		"transcode: too short for a preview: the lowest rendition has 1 segment(s)"))
	if len(evs) != 2 {
		t.Errorf("%d events, want one per COMPLETE", len(evs))
	}
	if keys := e.store.keys("preview/"); len(keys) != 0 || e.store.get("premium/"+id+"/"+version+"/master.m3u8") != nil {
		t.Errorf("preview %v, full master %q; want neither", keys, e.store.get("premium/"+id+"/"+version+"/master.m3u8"))
	}
}

// A copy into the preview that fails leaves the message on the queue with nothing published and
// no master; the next delivery publishes the result.
func TestPremiumFailedPreviewCopyIsRetried(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	job, id, version := e.premiumJob(t, lengths(4))
	e.mc.complete(t, job)
	e.store.failCopyTo = func(dst string) bool {
		return strings.HasPrefix(dst, "preview/") && strings.HasSuffix(dst, "_00002.ts")
	}
	if e.message(t, job, types.JobStatusComplete) {
		t.Fatal("COMPLETE settled with a failed copy")
	}
	if n := len(e.events(t)); n != 0 || e.store.get("preview/"+id+"/"+version+"/master.m3u8") != nil {
		t.Fatalf("%d events, preview master %q after the failed copy", n, e.store.get("preview/"+id+"/"+version+"/master.m3u8"))
	}
	e.store.failCopyTo = nil
	if !e.message(t, job, types.JobStatusComplete) {
		t.Fatal("COMPLETE message not done with")
	}
	sameResult(t, e.events(t), premiumCompleted(id, version, e.attemptOf(t, job), lengths(4)))
}

// A settle that created the preview master and failed on the full one: the next keeps the
// preview master as it is and creates the full one.
func TestPremiumKeepsEarlierPreviewMaster(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	job, id, version := e.premiumJob(t, lengths(2))
	full, preview := "premium/"+id+"/"+version+"/master.m3u8", "preview/"+id+"/"+version+"/master.m3u8"
	e.mc.complete(t, job)
	e.store.failCreate = func(key string) bool { return key == full }
	if e.message(t, job, types.JobStatusComplete) {
		t.Fatal("COMPLETE settled with a failed master")
	}
	kept := e.store.get(preview)
	if kept == nil || e.store.get(full) != nil {
		t.Fatalf("preview master %q, full master %q; want only the preview one", kept, e.store.get(full))
	}
	e.store.failCreate = nil
	if !e.message(t, job, types.JobStatusComplete) {
		t.Fatal("COMPLETE message not done with")
	}
	if got := e.store.get(preview); !slices.Equal(got, kept) {
		t.Errorf("preview master changed:\n%s\nwas\n%s", got, kept)
	}
	sameResult(t, e.events(t), premiumCompleted(id, version, e.attemptOf(t, job), lengths(2)))
}

// A job's premium flag picks the directory its outputs must be in; any other value is refused.
func TestCheckPremiumJob(t *testing.T) {
	t.Parallel()
	b := sampleBridge()
	premium := func(t *testing.T) *types.Job {
		ref := sampleRef()
		ref.premium = true
		return &types.Job{Queue: aws.String(testQueueARN), Settings: b.BuildJob(ref, sampleSource(t)).Settings,
			UserMetadata: b.BuildJob(ref, sampleSource(t)).UserMetadata}
	}
	if ref, err := b.checkJob(premium(t)); err != nil || !ref.premium {
		t.Fatalf("checkJob() = %+v, %v; want a premium ref", ref, err)
	}
	if ref, err := b.checkJob(completedJob(t)); err != nil || ref.premium {
		t.Fatalf("checkJob() of a regular job = %+v, %v", ref, err)
	}
	for name, f := range map[string]func(t *testing.T) *types.Job{
		"premium writing to media/": func(t *testing.T) *types.Job {
			j := premium(t)
			j.Settings = completedJob(t).Settings
			return j
		},
		"regular writing to premium/": func(t *testing.T) *types.Job {
			j := premium(t)
			delete(j.UserMetadata, metaPremium)
			return j
		},
		"flag not true": func(t *testing.T) *types.Job {
			j := premium(t)
			j.UserMetadata[metaPremium] = "false"
			return j
		},
	} {
		if _, err := b.checkJob(f(t)); err == nil {
			t.Errorf("%s: checkJob() succeeded", name)
		}
	}
}
