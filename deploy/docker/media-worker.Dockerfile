# media-worker image: the Go build of service.Dockerfile, with ffmpeg and ffprobe from Alpine on a scratch runtime.
# Distroless has no ffmpeg, so Alpine installs it, then the shell and apk are removed: a worker taken over by a crafted
# file has no shell or package manager, while the package database stays for trivy and grype to see ffmpeg's version.
# No secret goes into the build: credentials are environment variables given at run time.

# No `# syntax=` line: BuildKit's built-in frontend already runs RUN --mount, and a syntax image would be pulled
# from Docker Hub by a tag that can be pushed again, the one unpinned image of the build.

# Build stage: the Go release named by the go directive of go.mod (make vulncheck fails when they differ). Base images
# are pinned by the digest of their multi-arch index (linux/amd64 and linux/arm64), as in service.Dockerfile: a tag can
# be pushed again with other content, a digest cannot.
FROM golang:1.27.4-trixie@sha256:f18c3d73a184fb0582828510722e723b63a93f7188d11dd223d9be6f6880e65d AS build
WORKDIR /src

# Modules first, so the download layer is reused until go.mod or go.sum change.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

# Only the code the worker can import: generated proto code, shared internal/ and its own tree.
COPY gen/ gen/
COPY internal/ internal/
COPY services/media-worker/ services/media-worker/
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -o /app ./services/media-worker/cmd/media-worker

# Root filesystem stage: the tag keeps the 3.24 branch; the ffmpeg package is not pinned, since Alpine drops old builds
# from its repository once a fix lands. apk add leaves installed packages as they are, so apk upgrade first gives the
# base packages (zlib, ...) the branch's patches too, before the digest Renovate proposes catches up.
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS rootfs
# The last rm is one busybox process, so it can remove busybox itself and every applet link, /bin/sh among them. The
# package database keeps the entries of busybox and apk-tools, so scanners still report them.
RUN apk upgrade --no-cache \
    && apk add --no-cache ffmpeg \
    && install -d -o 65532 -g 65532 -m 0750 /work \
    && busybox rm -f /sbin/apk /usr/lib/libapk.so.* $(busybox --list-full | busybox sed 's|^|/|') /bin/busybox

# Runtime stage: scratch carries no environment, and the worker looks up ffmpeg and ffprobe in PATH (Alpine's value).
FROM scratch
COPY --from=rootfs / /
COPY --from=build /app /app
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
USER 65532:65532
ENTRYPOINT ["/app"]
