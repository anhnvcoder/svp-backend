package mediaconvert

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/mediaconvert"
	"github.com/aws/aws-sdk-go-v2/service/mediaconvert/types"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"

	mediav1 "github.com/anhnvcoder/svp-backend/gen/go/svp/media/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/transcode"
)

// Keys of the job's UserMetadata.
const (
	metaVideoID     = "video_id"
	metaVersion     = "version"
	metaAttempt     = "attempt"
	metaTraceparent = "traceparent"
)

// Settings of the job that are not in package transcode.
const (
	audioSelector   = "Audio Selector 1"
	audioSampleRate = 48_000
	// thumbnailBase is the base name of the frame capture: MediaConvert adds .<7 digits>.jpg.
	thumbnailBase = "thumb"
	// thumbnailQuality is the JPEG quality of the frame capture, MediaConvert's default.
	thumbnailQuality = 80
	// maxTimecodeFrame is the highest frame number a timecode names: its FF field has two digits.
	maxTimecodeFrame = 99
)

// jobIDPattern is the shape of a MediaConvert job ID (13 digits, a dash, 6 characters, as in
// 1700000000000-abc123), checked before the ID goes into a request path or a log.
var jobIDPattern = regexp.MustCompile(`^[0-9a-z]{1,32}(-[0-9a-z]{1,32}){0,3}$`)

// Source is what Probe tells of a source: the size as displayed, after the rotation of its
// container, the frame rate, the duration of its video track and whether it has sound.
type Source struct {
	Width, Height int
	FPS           float64
	Duration      time.Duration
	Audio         bool
}

// Inspect checks the probe of a source against the limits of package transcode: a reason other
// than UNSPECIFIED, with a detail, refuses it before any job.
func Inspect(results []types.ProbeResult) (Source, mediav1.TranscodeFailureReason, string) {
	if len(results) != 1 || results[0].Container == nil {
		return Source{}, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT, "probe found no container"
	}
	c := results[0].Container
	var src Source
	var video *types.Track
	for i, t := range c.Tracks {
		switch {
		case t.TrackType == types.TrackTypeVideo && video == nil && t.VideoProperties != nil:
			video = &c.Tracks[i]
		case t.TrackType == types.TrackTypeAudio:
			src.Audio = true
		}
	}
	if video == nil {
		return Source{}, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT, "probe found no video track"
	}
	vp := video.VideoProperties
	src.Width, src.Height = int(aws.ToInt32(vp.Width)), int(aws.ToInt32(vp.Height))
	if fr := vp.FrameRate; fr != nil && aws.ToInt32(fr.Denominator) > 0 {
		src.FPS = float64(aws.ToInt32(fr.Numerator)) / float64(aws.ToInt32(fr.Denominator))
	}
	if err := transcode.CheckVideo(src.Width, src.Height, src.FPS); err != nil {
		return Source{}, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT, err.Error()
	}
	if c.Duration == nil {
		return Source{}, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT, "probe found no duration"
	}
	if err := transcode.CheckDuration(seconds(*c.Duration)); err != nil {
		return Source{}, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_DURATION_EXCEEDED, err.Error()
	}
	src.Duration = seconds(*c.Duration)
	if video.Duration != nil {
		src.Duration = seconds(*video.Duration)
	}
	if src.FPS <= 0 || endFrame(src) < 0 {
		return Source{}, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT, "probe found no frame to encode"
	}
	// Automatic rotation turns a frame by 90 or 270 degrees, within 1 degree.
	if r := (int(aws.ToInt32(vp.Rotation))%360 + 360) % 360; abs(r-90) <= 1 || abs(r-270) <= 1 {
		src.Width, src.Height = src.Height, src.Width
	}
	return src, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_UNSPECIFIED, ""
}

func seconds(s float64) time.Duration {
	if math.IsNaN(s) || s < 0 {
		return 0
	}
	return time.Duration(math.Min(s, math.MaxInt64/float64(time.Second)) * float64(time.Second))
}

func abs(n int) int { return max(n, -n) }

// endFrame is the last frame the job encodes, counted from 0: the frame before the end of the
// video track or of transcode.MaxDuration, whichever comes first. Ending inside the track keeps
// the job off error 1060 (a clip end outside the input). Every job is clipped, so none encodes
// past the cap even when Probe reports a shorter track than the file holds.
func endFrame(src Source) int {
	return int(math.Floor(min(src.Duration, transcode.MaxDuration).Seconds()*src.FPS)) - 1
}

// endTimecode writes endFrame as HH:MM:SS:FF at the nominal (rounded) frame rate. FF has two
// digits, so above 100 fps a clip whose last frame is past frame 99 of its second ends at frame
// 99 instead: the job drops up to fps-100 frames at the end (20 frames, under 0.2 s, at 120 fps),
// a cost accepted for sources over 100 fps, which are rare.
func endTimecode(src Source) string {
	fps := max(int(math.Round(src.FPS)), 1)
	n := endFrame(src)
	s := n / fps
	return fmt.Sprintf("%02d:%02d:%02d:%02d", s/3600, s/60%60, s%60, min(n%fps, maxTimecodeFrame))
}

// jobRef is what a job's UserMetadata says it is.
type jobRef struct {
	videoID, version, attempt string
	traceparent               string
}

// attemptDir is the S3 URL of the directory every object of the job goes to.
func (b *Bridge) attemptDir(r jobRef) string {
	return "s3://" + b.cfg.MediaBucket + "/" + objstore.MediaPrefix + r.videoID + "/" + r.version + "/" + r.attempt + "/"
}

// BuildJob returns the CreateJob request for ref's attempt at src: one HLS output group with the
// ladder of package transcode on the displayed size, and one frame capture.
func (b *Bridge) BuildJob(ref jobRef, src Source) *mediaconvert.CreateJobInput {
	input := types.Input{
		FileInput:      aws.String("s3://" + b.cfg.UploadsBucket + "/" + objstore.UploadsPrefix + ref.videoID),
		TimecodeSource: types.InputTimecodeSourceZerobased,
		InputClippings: []types.InputClipping{{EndTimecode: aws.String(endTimecode(src))}},
		VideoSelector:  &types.VideoSelector{Rotate: types.InputRotateAuto},
	}
	var audio []types.AudioDescription
	if src.Audio {
		input.AudioSelectors = map[string]types.AudioSelector{audioSelector: {DefaultSelection: types.AudioDefaultSelectionDefault}}
		audio = []types.AudioDescription{{
			AudioSourceName: aws.String(audioSelector),
			CodecSettings: &types.AudioCodecSettings{Codec: types.AudioCodecAac, AacSettings: &types.AacSettings{
				Bitrate: aws.Int32(transcode.AudioBitrate), CodingMode: types.AacCodingModeCodingMode20,
				SampleRate: aws.Int32(audioSampleRate),
			}},
		}}
	}
	var outputs []types.Output
	for _, r := range transcode.Renditions(src.Width, src.Height) {
		outputs = append(outputs, types.Output{
			NameModifier:      aws.String(transcode.PlaylistModifier + r.Name),
			ContainerSettings: &types.ContainerSettings{Container: types.ContainerTypeM3u8},
			VideoDescription: &types.VideoDescription{
				Width: aws.Int32(int32(r.Width)), Height: aws.Int32(int32(r.Height)), //nolint:gosec // at most 4096
				CodecSettings: &types.VideoCodecSettings{Codec: types.VideoCodecH264, H264Settings: &types.H264Settings{
					RateControlMode:    types.H264RateControlModeVbr,
					Bitrate:            aws.Int32(int32(r.Bitrate)),                        //nolint:gosec // ladder constants
					MaxBitrate:         aws.Int32(int32(transcode.PeakBitrate(r.Bitrate))), //nolint:gosec // ladder constants
					HrdBufferSize:      aws.Int32(int32(transcode.BufferSize(r.Bitrate))),  //nolint:gosec // ladder constants
					GopSize:            aws.Float64(transcode.KeyframeSeconds),
					GopSizeUnits:       types.H264GopSizeUnitsSeconds,
					SceneChangeDetect:  types.H264SceneChangeDetectDisabled,
					CodecProfile:       types.H264CodecProfileHigh,
					CodecLevel:         types.H264CodecLevelAuto,
					InterlaceMode:      types.H264InterlaceModeProgressive,
					QualityTuningLevel: types.H264QualityTuningLevelSinglePass,
				}},
			},
			AudioDescriptions: audio,
		})
	}
	thumbW, thumbH := transcode.ThumbnailSize(src.Width, src.Height)
	dir := b.attemptDir(ref)
	metadata := map[string]string{metaVideoID: ref.videoID, metaVersion: ref.version, metaAttempt: ref.attempt}
	if ref.traceparent != "" {
		metadata[metaTraceparent] = ref.traceparent
	}
	return &mediaconvert.CreateJobInput{
		Queue:              aws.String(b.cfg.QueueARN),
		Role:               aws.String(b.cfg.RoleARN),
		ClientRequestToken: aws.String(ref.attempt),
		UserMetadata:       metadata,
		Settings: &types.JobSettings{
			Inputs: []types.Input{input},
			OutputGroups: []types.OutputGroup{
				{
					Name: aws.String("HLS"),
					OutputGroupSettings: &types.OutputGroupSettings{
						Type: types.OutputGroupTypeHlsGroupSettings,
						HlsGroupSettings: &types.HlsGroupSettings{
							Destination:            aws.String(dir + transcode.PlaylistBase),
							DirectoryStructure:     types.HlsDirectoryStructureSingleDirectory,
							SegmentLength:          aws.Int32(transcode.SegmentSeconds),
							MinSegmentLength:       aws.Int32(0),
							SegmentControl:         types.HlsSegmentControlSegmentedFiles,
							OutputSelection:        types.HlsOutputSelectionManifestsAndSegments,
							ManifestDurationFormat: types.HlsManifestDurationFormatFloatingPoint,
						},
					},
					Outputs: outputs,
				},
				{
					Name: aws.String("Thumbnail"),
					OutputGroupSettings: &types.OutputGroupSettings{
						Type:              types.OutputGroupTypeFileGroupSettings,
						FileGroupSettings: &types.FileGroupSettings{Destination: aws.String(dir + thumbnailBase)},
					},
					Outputs: []types.Output{{
						ContainerSettings: &types.ContainerSettings{Container: types.ContainerTypeRaw},
						VideoDescription: &types.VideoDescription{
							Width: aws.Int32(int32(thumbW)), Height: aws.Int32(int32(thumbH)), //nolint:gosec // at most 4096
							CodecSettings: &types.VideoCodecSettings{
								Codec: types.VideoCodecFrameCapture,
								FrameCaptureSettings: &types.FrameCaptureSettings{
									FramerateNumerator: aws.Int32(1), FramerateDenominator: aws.Int32(1),
									MaxCaptures: aws.Int32(1), Quality: aws.Int32(thumbnailQuality),
								},
							},
						},
					}},
				},
			},
		},
	}
}

// traceparentOf is the W3C traceparent of the span in ctx, empty without one.
func traceparentOf(ctx context.Context) string {
	c := propagation.MapCarrier{}
	propagation.TraceContext{}.Inject(ctx, c)
	return c.Get(metaTraceparent)
}

// traceContext is ctx with the remote parent traceparent names; a missing or malformed one
// leaves ctx without a span, so a new trace starts.
func traceContext(ctx context.Context, traceparent string) context.Context {
	ctx = trace.ContextWithSpanContext(ctx, trace.SpanContext{})
	return propagation.TraceContext{}.Extract(ctx, propagation.MapCarrier{metaTraceparent: traceparent})
}

// checkJob returns what job's metadata says it is, or an error when the job is not one the
// bridge can vouch for: another queue, metadata missing or not canonical UUIDs, or an output
// group writing outside the attempt directory.
func (b *Bridge) checkJob(job *types.Job) (jobRef, error) {
	if aws.ToString(job.Queue) != b.cfg.QueueARN {
		return jobRef{}, errors.New("job is not in the queue of this environment")
	}
	ref := jobRef{
		videoID: job.UserMetadata[metaVideoID], version: job.UserMetadata[metaVersion],
		attempt: job.UserMetadata[metaAttempt], traceparent: job.UserMetadata[metaTraceparent],
	}
	for _, v := range []string{ref.videoID, ref.version, ref.attempt} {
		if _, err := ids.Parse(v); err != nil {
			return jobRef{}, errors.New("job metadata lacks a canonical video_id, version or attempt")
		}
	}
	if job.Settings == nil || len(job.Settings.OutputGroups) == 0 {
		return jobRef{}, errors.New("job has no output group")
	}
	dir := b.attemptDir(ref)
	for _, g := range job.Settings.OutputGroups {
		var dest string
		if s := g.OutputGroupSettings; s != nil && s.HlsGroupSettings != nil && s.FileGroupSettings == nil {
			dest = aws.ToString(s.HlsGroupSettings.Destination)
		} else if s != nil && s.FileGroupSettings != nil && s.HlsGroupSettings == nil {
			dest = aws.ToString(s.FileGroupSettings.Destination)
		}
		name, ok := strings.CutPrefix(dest, dir)
		if !ok || !objstore.IsMediaKey(objstore.MediaPrefix+ref.videoID+"/"+name, ref.videoID) || strings.Contains(name, "/") {
			return jobRef{}, errors.New("job writes outside its attempt directory")
		}
	}
	return ref, nil
}

// inputErrors are the MediaConvert error codes the documentation blames on the input file; any
// other code fails the version as RETRIES_EXHAUSTED.
var inputErrors = []int32{1010, 1020, 1021, 1030, 1056, 1060, 1075, 1076, 1092}

// jobFailure maps a job in ERROR to the reason and detail of its transcode.failed.
func jobFailure(job *types.Job) (mediav1.TranscodeFailureReason, string) {
	code := aws.ToInt32(job.ErrorCode)
	reason := mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_RETRIES_EXHAUSTED
	if slices.Contains(inputErrors, code) {
		reason = mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT
	}
	return reason, fmt.Sprintf("mediaconvert job %s: error %d: %s", aws.ToString(job.Id), code, aws.ToString(job.ErrorMessage))
}

// JobRenditions returns the renditions of a completed job, lowest first: names from the name
// modifiers of its HLS outputs, sizes as MediaConvert reports them. The order of the reported
// outputs is not the order of the settings, so each size is matched to the step of the ladder
// with the same short side; a single source rendition takes the only size.
func JobRenditions(job *types.Job) ([]transcode.Rendition, error) {
	if job.Settings == nil {
		return nil, errors.New("job has no settings")
	}
	group := slices.IndexFunc(job.Settings.OutputGroups, func(g types.OutputGroup) bool {
		return g.OutputGroupSettings != nil && g.OutputGroupSettings.HlsGroupSettings != nil
	})
	if group < 0 || group >= len(job.OutputGroupDetails) {
		return nil, errors.New("job reports no HLS output group")
	}
	var sizes [][2]int
	for _, d := range job.OutputGroupDetails[group].OutputDetails {
		if d.VideoDetails == nil {
			return nil, errors.New("job reports an HLS output without a video size")
		}
		sizes = append(sizes, [2]int{int(aws.ToInt32(d.VideoDetails.WidthInPx)), int(aws.ToInt32(d.VideoDetails.HeightInPx))})
	}
	outputs := job.Settings.OutputGroups[group].Outputs
	if len(outputs) != len(sizes) {
		return nil, fmt.Errorf("job reports %d HLS outputs for %d in its settings", len(sizes), len(outputs))
	}
	var rs []transcode.Rendition
	for _, o := range outputs {
		name, ok := strings.CutPrefix(aws.ToString(o.NameModifier), transcode.PlaylistModifier)
		short, bitrate, known := transcode.Step(name)
		if !ok || !known || slices.ContainsFunc(rs, func(r transcode.Rendition) bool { return r.Name == name }) {
			return nil, fmt.Errorf("job has an HLS output %q outside the ladder", aws.ToString(o.NameModifier))
		}
		k := slices.IndexFunc(sizes, func(s [2]int) bool { return short == 0 || min(s[0], s[1]) == short })
		if k < 0 || (short == 0 && len(outputs) != 1) {
			return nil, fmt.Errorf("job reports no size for rendition %s", name)
		}
		rs = append(rs, transcode.Rendition{Name: name, Width: sizes[k][0], Height: sizes[k][1], Bitrate: bitrate})
		sizes = slices.Delete(sizes, k, k+1)
	}
	slices.SortStableFunc(rs, func(a, b transcode.Rendition) int { return a.Bitrate - b.Bitrate })
	return rs, nil
}

// stateChange is the part of an EventBridge "MediaConvert Job State Change" event the bridge
// reads.
type stateChange struct {
	Source     string `json:"source"`
	DetailType string `json:"detail-type"`
	Detail     struct {
		JobID string `json:"jobId"`
	} `json:"detail"`
}

// parseEvent returns the job ID of an SQS message body holding a MediaConvert job state change.
// The rest of the event is not trusted: the bridge reads the job itself.
func parseEvent(body *string) (string, error) {
	var ev stateChange
	if body == nil || json.Unmarshal([]byte(*body), &ev) != nil {
		return "", errors.New("message is not a JSON event")
	}
	if ev.Source != "aws.mediaconvert" || ev.DetailType != "MediaConvert Job State Change" {
		return "", errors.New("message is not a MediaConvert job state change")
	}
	if !jobIDPattern.MatchString(ev.Detail.JobID) {
		return "", errors.New("message has no well-formed job ID")
	}
	return ev.Detail.JobID, nil
}

// getJob returns job id, an error for one that is not there or cannot be read.
func (b *Bridge) getJob(ctx context.Context, id string) (*types.Job, error) {
	out, err := b.mc.GetJob(ctx, &mediaconvert.GetJobInput{Id: aws.String(id)})
	if err != nil {
		return nil, fmt.Errorf("get job %s: %w", id, err)
	}
	if out.Job == nil || aws.ToString(out.Job.Id) != id {
		return nil, fmt.Errorf("get job %s: no such job in the answer", id)
	}
	return out.Job, nil
}
