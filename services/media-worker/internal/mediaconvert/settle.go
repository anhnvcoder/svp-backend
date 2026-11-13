package mediaconvert

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/mediaconvert"
	"github.com/aws/aws-sdk-go-v2/service/mediaconvert/types"

	mediav1 "github.com/anhnvcoder/svp-backend/gen/go/svp/media/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/transcode"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/worker"
)

const (
	// maxRecordBytes caps a job record read back: one line of a few dozen bytes.
	maxRecordBytes = 4 << 10
	// recordedDetail is the detail of a transcode.failed from a recorded reason: the same for
	// every publish of the version, so the cause is logged when the reason is recorded.
	recordedDetail = "failure recorded before any MediaConvert job"
)

// record is a job record: the job of the version, or the reason it failed before any job.
type record struct {
	Attempt string `json:"attempt,omitempty"`
	JobID   string `json:"job_id,omitempty"`
	Reason  string `json:"reason,omitempty"`
}

// reason is the failure reason of a record without a job, UNSPECIFIED for a job record.
func (r record) reason() mediav1.TranscodeFailureReason {
	return mediav1.TranscodeFailureReason(mediav1.TranscodeFailureReason_value[r.Reason])
}

func (r record) valid() bool {
	if r.Reason != "" {
		return r.Attempt == "" && r.JobID == "" && r.reason() != mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_UNSPECIFIED
	}
	_, err := ids.Parse(r.Attempt)
	return err == nil && jobIDPattern.MatchString(r.JobID)
}

func recordKey(id, version string) string {
	return objstore.JobsPrefix + id + "/" + version + ".json"
}

// readRecord returns the record of the version, false when storage holds none.
func (b *Bridge) readRecord(ctx context.Context, dir, id, version string) (record, bool, error) {
	key := recordKey(id, version)
	// Listing first: without s3:ListBucket on the key, a GET of a missing key is a 403.
	exists, err := b.store.Exists(ctx, key)
	if err != nil || !exists {
		return record{}, false, err
	}
	path := filepath.Join(dir, "record.json")
	if err := b.store.Download(ctx, key, path, maxRecordBytes); err != nil {
		return record{}, false, err
	}
	data, err := os.ReadFile(path) //nolint:gosec // the file just downloaded into the try's directory
	if err != nil {
		return record{}, false, err
	}
	var r record
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&r); err != nil || !r.valid() {
		return record{}, false, fmt.Errorf("job record %s is malformed", key)
	}
	return r, true, nil
}

// writeRecord creates the record of the version unless one exists, and returns the record that
// decides it: r, or the one written first.
func (b *Bridge) writeRecord(ctx context.Context, dir, id, version string, r record) (record, error) {
	data, err := json.Marshal(r)
	if err != nil {
		return record{}, err
	}
	path := filepath.Join(dir, "new-record.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return record{}, fmt.Errorf("write job record: %w", err)
	}
	err = b.store.Create(ctx, recordKey(id, version), path, "application/json", "")
	if !errors.Is(err, objstore.ErrExists) {
		return r, err
	}
	first, ok, err := b.readRecord(ctx, dir, id, version)
	if err == nil && !ok {
		err = fmt.Errorf("job record %s exists but is not listed", recordKey(id, version))
	}
	return first, err
}

// settled is the outcome of settling a version.
type settled struct {
	// ev is the event to publish, nil while the job runs.
	ev *mediav1.TranscodeEvent
	// job is the job of the record, nil for a recorded reason.
	job *types.Job
}

func (s settled) jobID() string {
	if s.job == nil {
		return ""
	}
	return aws.ToString(s.job.Id)
}

// uploaded settles the version of a video.uploaded, submitting a job when it has no record.
func (b *Bridge) uploaded(ctx context.Context, dir, id, version string) (settled, error) {
	r, ok, err := b.readRecord(ctx, dir, id, version)
	if err != nil {
		return settled{}, err
	}
	if !ok {
		if r, err = b.submit(ctx, dir, id, version); err != nil {
			return settled{}, err
		}
	}
	return b.settle(ctx, dir, id, version, r, nil)
}

// submit probes the source and creates a job for it, or records why it cannot have one, and
// returns the record that decides the version.
func (b *Bridge) submit(ctx context.Context, dir, id, version string) (record, error) {
	out, err := b.mc.Probe(ctx, &mediaconvert.ProbeInput{InputFiles: []types.ProbeInputFile{{
		FileUrl: aws.String("s3://" + b.cfg.UploadsBucket + "/" + objstore.UploadsPrefix + id),
	}}})
	var src Source
	reason, detail := mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_UNSPECIFIED, ""
	switch _, missing := errors.AsType[*types.NotFoundException](err); {
	case missing:
		reason, detail = mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_SOURCE_MISSING, err.Error()
	case err != nil:
		return record{}, fmt.Errorf("probe: %w", err)
	default:
		src, reason, detail = Inspect(out.ProbeResults)
	}
	if reason != mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_UNSPECIFIED {
		b.logger.LogAttrs(ctx, slog.LevelInfo, "source refused", slog.String("reason", reason.String()),
			slog.String("detail", worker.Scrub(b.cfg.WorkDir, detail)))
		return b.writeRecord(ctx, dir, id, version, record{Reason: reason.String()})
	}
	ref := jobRef{videoID: id, version: version, attempt: b.newID(), traceparent: traceparentOf(ctx)}
	job, err := b.mc.CreateJob(ctx, b.BuildJob(ref, src))
	if err != nil {
		return record{}, fmt.Errorf("create job: %w", err)
	}
	if job.Job == nil || !jobIDPattern.MatchString(aws.ToString(job.Job.Id)) {
		return record{}, errors.New("create job: no well-formed job ID in the answer")
	}
	return b.writeRecord(ctx, dir, id, version, record{Attempt: ref.attempt, JobID: aws.ToString(job.Job.Id)})
}

// giveUp ends the last try of a video.uploaded: the version is recorded as RETRIES_EXHAUSTED,
// unless a record came first, and settled.
func (b *Bridge) giveUp(ctx context.Context, dir, id, version string, cause error) (settled, error) {
	reason := mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_RETRIES_EXHAUSTED
	b.logger.LogAttrs(ctx, slog.LevelWarn, "transcode retries exhausted", slog.String("error", b.scrub(cause)))
	r, err := b.writeRecord(ctx, dir, id, version, record{Reason: reason.String()})
	if err != nil {
		return settled{}, err
	}
	return b.settle(ctx, dir, id, version, r, nil)
}

// jobEnded settles the version of a job that reached COMPLETE or ERROR, recording that job
// first when the version has no record.
func (b *Bridge) jobEnded(ctx context.Context, dir string, ref jobRef, job *types.Job) (settled, error) {
	r, ok, err := b.readRecord(ctx, dir, ref.videoID, ref.version)
	if err != nil {
		return settled{}, err
	}
	if !ok {
		r, err = b.writeRecord(ctx, dir, ref.videoID, ref.version, record{Attempt: ref.attempt, JobID: aws.ToString(job.Id)})
		if err != nil {
			return settled{}, err
		}
	}
	return b.settle(ctx, dir, ref.videoID, ref.version, r, job)
}

// settle returns the result of the version decided by r: the recorded reason, or the state of
// the recorded job. known is a job already read, used when it is the recorded one.
func (b *Bridge) settle(ctx context.Context, dir, id, version string, r record, known *types.Job) (settled, error) {
	if reason := r.reason(); reason != mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_UNSPECIFIED {
		return settled{ev: failedOf(id, reason, recordedDetail)}, nil
	}
	job := known
	if job == nil || aws.ToString(job.Id) != r.JobID {
		var err error
		if job, err = b.getJob(ctx, r.JobID); err != nil {
			return settled{}, err
		}
	}
	ref, err := b.checkJob(job)
	if err != nil {
		return settled{}, fmt.Errorf("recorded job %s: %w", r.JobID, err)
	}
	if ref.videoID != id || ref.version != version || ref.attempt != r.Attempt {
		return settled{}, fmt.Errorf("recorded job %s belongs to another attempt", r.JobID)
	}
	switch job.Status {
	case types.JobStatusComplete:
		ev, err := b.completed(ctx, dir, ref, job)
		return settled{ev: ev, job: job}, err
	case types.JobStatusError:
		reason, detail := jobFailure(job)
		return settled{ev: failedOf(id, reason, detail), job: job}, nil
	case types.JobStatusSubmitted, types.JobStatusProgressing:
		return settled{job: job}, nil
	}
	return settled{}, fmt.Errorf("recorded job %s is %s", r.JobID, job.Status)
}

// completed gives every object of a completed job the headers of package worker, then creates
// the master of the version unless it exists, and reads the result back from storage. Creating
// the master records the version's ready sample of svp.transcode.duration.
func (b *Bridge) completed(ctx context.Context, dir string, ref jobRef, job *types.Job) (*mediav1.TranscodeEvent, error) {
	prefix := objstore.MediaPrefix + ref.videoID + "/" + ref.version + "/"
	exists, err := b.store.Exists(ctx, prefix+transcode.MasterPlaylist)
	if err != nil {
		return nil, err
	}
	if !exists {
		master, err := b.prepare(ctx, prefix, ref.attempt, job)
		if err != nil {
			return nil, err
		}
		path := filepath.Join(dir, "new-"+transcode.MasterPlaylist)
		if err := os.WriteFile(path, master, 0o600); err != nil {
			return nil, fmt.Errorf("write master: %w", err)
		}
		contentType, _ := transcode.ContentType(transcode.MasterPlaylist)
		err = b.store.Create(ctx, prefix+transcode.MasterPlaylist, path, contentType, worker.CacheControl)
		switch {
		case err == nil:
			// Right away, not after the publish: a read or publish failing next is retried by a try
			// that finds the master, and only the try that created it counts the version.
			b.observe(ctx, job, "ready")
		case !errors.Is(err, objstore.ErrExists):
			return nil, err
		}
	}
	return worker.ReadStored(ctx, b.store, dir, ref.videoID, prefix)
}

// prepare copies every object of the attempt in place with the headers of package worker and
// the frame capture to thumbnail.jpg, and returns the master naming the job's renditions. It
// fails before the master on any object missing or out of place, so a later try starts over.
func (b *Bridge) prepare(ctx context.Context, prefix, attempt string, job *types.Job) ([]byte, error) {
	renditions, err := JobRenditions(job)
	if err != nil {
		return nil, err
	}
	dir := prefix + attempt + "/"
	keys, err := b.store.List(ctx, dir)
	if err != nil {
		return nil, err
	}
	for _, r := range renditions {
		if !slices.Contains(keys, dir+transcode.PlaylistName(r.Name)) {
			return nil, fmt.Errorf("playlist of rendition %s is missing", r.Name)
		}
	}
	thumb := ""
	for _, key := range keys {
		name := strings.TrimPrefix(key, dir)
		contentType, ok := transcode.ContentType(name)
		if !ok || strings.Contains(name, "/") {
			return nil, fmt.Errorf("unexpected object %s in the attempt directory", name)
		}
		if thumb == "" && strings.HasPrefix(name, thumbnailBase+".") && strings.HasSuffix(name, ".jpg") {
			thumb = key
		}
		if err := b.store.Copy(ctx, key, key, contentType, worker.CacheControl); err != nil {
			return nil, err
		}
	}
	if thumb == "" {
		return nil, errors.New("frame capture is missing")
	}
	contentType, _ := transcode.ContentType(transcode.Thumbnail)
	if err := b.store.Copy(ctx, thumb, dir+transcode.Thumbnail, contentType, worker.CacheControl); err != nil {
		return nil, err
	}
	return transcode.BuildMaster(attempt, renditions), nil
}
