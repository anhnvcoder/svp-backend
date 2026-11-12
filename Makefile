# Build, generate, lint and test entry point for the monorepo. `make help` lists the targets.
# Design notes: docs/reference/make.md.

# Pinned tool versions, installed by `make tools` rather than as `tool` directives in go.mod: sqlc and golangci-lint
# would pull hundreds of modules into the application's dependency graph, and `go install` builds each of them with
# this machine's Go.
# renovate: datasource=go depName=google.golang.org/protobuf
PROTOC_GEN_GO_VERSION      := v1.36.12
# renovate: datasource=go depName=google.golang.org/grpc/cmd/protoc-gen-go-grpc
PROTOC_GEN_GO_GRPC_VERSION := v1.6.2
# renovate: datasource=go depName=github.com/sqlc-dev/sqlc
SQLC_VERSION               := v1.31.1
# renovate: datasource=go depName=github.com/golangci/golangci-lint/v2
GOLANGCI_LINT_VERSION      := v2.15.0
# renovate: datasource=go depName=github.com/zricethezav/gitleaks/v8
GITLEAKS_VERSION           := v8.30.1
# `go install` leaves the Sloth version empty and Sloth would then write "dev" in the header of the file it generates.
# renovate: datasource=go depName=github.com/slok/sloth
SLOTH_VERSION              := v0.16.0
# k3d: without both -X flags it reports v5-dev and pulls its proxy and tools images as :latest, and its default node
# image is an older k3s; the node image itself is pinned by digest in deploy/k8s/k3d.yaml.
# renovate: datasource=go depName=github.com/k3d-io/k3d/v5
K3D_VERSION                := v5.9.0
# renovate: datasource=docker depName=rancher/k3s
K3S_IMAGE_TAG              := v1.36.6-k3s1
# One line on purpose: a backslash-newline inside the single quotes of a recipe reaches the shell as a literal backslash
# on GNU Make 4.x (Make 3.81 joined the lines), and the linker then gets a broken -ldflags.
K3D_LDFLAGS                := -X github.com/k3d-io/k3d/v5/version.Version=$(K3D_VERSION) -X github.com/k3d-io/k3d/v5/version.K3sVersion=$(K3S_IMAGE_TAG)
# `go install` and not its image: the `script` steps need the kubectl, curl, jq, nc, openssl and docker of the machine
# that runs them. deploy/k8s/drills/.schemas/ holds the StepTemplate schema of this same tag (make chainsaw-lint fails
# when they differ).
# renovate: datasource=go depName=github.com/kyverno/chainsaw
CHAINSAW_VERSION           := v0.2.15
# The go.mod of helmfile holds replace directives, which `go install <module>@<version>` refuses: make tools downloads
# the module through the Go module proxy (checked against the checksum database, as go install does) and builds it in
# its own folder, with the version helmfile --version reports.
# renovate: datasource=go depName=github.com/helmfile/helmfile
HELMFILE_VERSION           := v1.8.2
# actionlint also runs shellcheck on every `run:` script when shellcheck is on PATH: the CI runner has it, a dev
# machine need not.
# renovate: datasource=go depName=github.com/rhysd/actionlint
ACTIONLINT_VERSION         := v1.7.12
# renovate: datasource=go depName=golang.org/x/vuln
GOVULNCHECK_VERSION        := v1.9.0

# CI only (`make ci-tools`, Linux amd64 runner): a dev machine installs buf and Helm with Homebrew at these versions.
# Helm's archive is checked against the sha256 published with the release (helm-<version>-linux-amd64.tar.gz.sha256sum),
# so the two lines change together; `go install` of Helm is not a documented way and reports a wrong version.
# renovate: datasource=go depName=github.com/bufbuild/buf
BUF_VERSION                := v1.75.0
# renovate: datasource=github-releases depName=helm/helm
HELM_VERSION               := v4.3.1
HELM_LINUX_AMD64_SHA256    := 0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b
# Scanner and SBOM generator, run from their official images pinned by digest, the same reference on a dev machine and
# in CI: nothing to install and no setup action to trust (both trivy setup actions were hijacked in March 2026), and a
# digest cannot be moved like a tag.
# renovate: datasource=docker depName=ghcr.io/aquasecurity/trivy
TRIVY_IMAGE := ghcr.io/aquasecurity/trivy:0.76.0@sha256:2416d1f74045b57274df1a340eee6b510cacd73c66a6ccb8da092b117eb7d222
# renovate: datasource=docker depName=ghcr.io/anchore/syft
SYFT_IMAGE  := ghcr.io/anchore/syft:v1.54.1@sha256:3eb5379ba7b409c3f4069b686110527af0c47df993fa5c10d13e7cf34f49b1aa
# renovate: datasource=docker depName=ghcr.io/anchore/grype
GRYPE_IMAGE := ghcr.io/anchore/grype:v0.121.0@sha256:621d56d1d68106b787022c81546f7e0a36202a25d1239f0c20195fab8c16f7ea
# cosign: signing happens in CI alone (.github/actions/image-sign runs this image); on a dev machine it only verifies
# releases (deploy/ci/verify-release.sh, and `make k8s-gitops-up` before it creates anything).
# renovate: datasource=docker depName=ghcr.io/sigstore/cosign/cosign
COSIGN_IMAGE := ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8
# Load generator of the SLO scripts in deploy/k6/, from its official image
# pinned by digest: the same k6 on a dev machine, in CI and as a Job in the cloud cluster, where the 1 000 req/s run has to
# start inside the cluster to measure the system rather than the home network. The k6 of Homebrew is not pinned. v2: the v1
# line only gets security fixes.
# renovate: datasource=docker depName=grafana/k6
K6_IMAGE := grafana/k6:2.3.0@sha256:2dd4756ec6e14e62778916e1eb850108e4b499304c02df56760fa0bdb0fba0b8
# DAST (make dast): the same pinned image on a dev machine and in the CI job stack.
# renovate: datasource=docker depName=schemathesis/schemathesis
SCHEMATHESIS_IMAGE := schemathesis/schemathesis:4.32.4@sha256:b501f25d00fa6e2b393ddd1b525a11bb560d593fd06268491595c2e439090bf0
# The image is FROM scratch with kubeconform and openapi2jsonschema, which turns the CRDs of the pinned charts into
# schemas (make helm-check), so no Python is needed. make cloud-check checks the k6 Job with no CRD schema. The image
# runs as root unless docker run gets --user.
# renovate: datasource=docker depName=ghcr.io/yannh/kubeconform
KUBECONFORM_IMAGE := ghcr.io/yannh/kubeconform:v0.8.0@sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e
# The Kyverno CLI is the minor of the Kyverno the clusters run (chart kyverno of argocd/apps/components.json in
# svp-gitops), so it reads the policies as admission would; no cluster, no network.
# renovate: datasource=docker depName=ghcr.io/kyverno/kyverno-cli
KYVERNO_CLI_IMAGE := ghcr.io/kyverno/kyverno-cli:v1.19.1@sha256:ced7b2be0b04250cabfe695f15307f69eb715fe23234816388af4f3812915b2a
# oasdiff compares the spec of a pull request with its base (make api-contract-check), ORAS pushes a new version to
# GHCR as an OCI artifact on main (deploy/ci/contract.sh); no GitHub Action of either is used.
# renovate: datasource=docker depName=tufin/oasdiff
OASDIFF_IMAGE := tufin/oasdiff:v1.34.1@sha256:67a23cfea7d251e2ae34ee703ac8733c5d96bc2e7b90fd0f4d475ec99367b85f
# renovate: datasource=docker depName=ghcr.io/oras-project/oras
ORAS_IMAGE := ghcr.io/oras-project/oras:v1.3.6@sha256:9cfb578be975b762fd898b9d004243d8003aeb807a3e15b2ed212cdd1326c9eb
# yq of the steps of images.yml that write svp-gitops (jobs promote and promote-prd, through yq_ of deploy/ci/common.sh),
# from its official image pinned by digest, run without network: the yq preinstalled on the runner changes with the
# runner image, unseen by Renovate and unreviewed, and these steps write the deployment repository.
# renovate: datasource=docker depName=mikefarah/yq
YQ_IMAGE := mikefarah/yq:4.54.1@sha256:4b3d9475d65571d28cbb19544d3820ec2945e4c8b2f18279394282b8dc3a592e
# conftest applies the Rego policies of deploy/ci/ignorefile-policies/ (the scan gate's ignore files) and
# deploy/ci/gitops-tree-policies/ (a tree of svp-gitops), without network. yq above finds a key written twice, which
# conftest's parser hides.
# renovate: datasource=docker depName=openpolicyagent/conftest
CONFTEST_IMAGE := openpolicyagent/conftest:v0.71.1@sha256:0e77cdf7c1fcde035f3c579e4aaa6664ee2a8be5777eaa9af9f520cdd02280c0
# Regal, the linter of the OPA project, for those Rego policies; the image is the one its README gives.
# renovate: datasource=docker depName=ghcr.io/open-policy-agent/regal
REGAL_IMAGE := ghcr.io/open-policy-agent/regal:0.43.0@sha256:29460f0ec1340d37f6c0c74bcbd88dd232fd8382c7a2337f0684415bd4c46da1

# Tools installed by `go install` land here; the PATH of the caller is not assumed to contain it.
GOBIN ?= $(shell go env GOPATH)/bin
export PATH := $(GOBIN):$(PATH)

# Packages for vet, lint and test; narrow them with e.g. `make test PKGS=./services/user-service/...`.
PKGS ?= ./...
# Extra flags put before the packages, empty by default: `make test TESTFLAGS=-count=1` runs every test again instead of
# reporting cached results; CI passes LINTFLAGS to add a SARIF report beside golangci-lint's text output.
TESTFLAGS ?=
LINTFLAGS ?=

# Superuser DSN of the native dev Postgres on the machine; integration tests create their own databases from it.
SVP_TEST_POSTGRES_URL ?= postgres://postgres:postgres@127.0.0.1:5432/postgres?sslmode=disable
# Local Redis, db 15: the project's test database, used by no service or other project, so tests never touch their data
# and never need FLUSHDB.
SVP_TEST_REDIS_URL ?= redis://127.0.0.1:6379/15

.DEFAULT_GOAL := help

.PHONY: help tools ci-tools generate generate-go generate-check slo otelcol-validate fmt-check vet lint actionlint buf-lint vulncheck test fuzz \
	cover check check-go helm-check helm-docs helm-docs-check kyverno-test conftest-verify regal-lint regal-fix chainsaw-lint trivy-config grype renovate-check zizmor api-contract-check hooks web-e2e measure-web measure-upload \
	web-lighthouse web-sourcemaps docs-check

help: ## List the targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

tools: ## Install the pinned code generators, linters, vulnerability and secret scanners, SLO generator, k3d, Chainsaw and helmfile into GOBIN
	GOBIN=$(GOBIN) go install google.golang.org/protobuf/cmd/protoc-gen-go@$(PROTOC_GEN_GO_VERSION)
	GOBIN=$(GOBIN) go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@$(PROTOC_GEN_GO_GRPC_VERSION)
	GOBIN=$(GOBIN) go install github.com/sqlc-dev/sqlc/cmd/sqlc@$(SQLC_VERSION)
	GOBIN=$(GOBIN) go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)
	GOBIN=$(GOBIN) go install github.com/rhysd/actionlint/cmd/actionlint@$(ACTIONLINT_VERSION)
	GOBIN=$(GOBIN) go install golang.org/x/vuln/cmd/govulncheck@$(GOVULNCHECK_VERSION)
	GOBIN=$(GOBIN) go install github.com/zricethezav/gitleaks/v8@$(GITLEAKS_VERSION)
	GOBIN=$(GOBIN) go install -ldflags='-X github.com/slok/sloth/internal/info.Version=$(SLOTH_VERSION)' \
		github.com/slok/sloth/cmd/sloth@$(SLOTH_VERSION)
	GOBIN=$(GOBIN) go install -ldflags='$(K3D_LDFLAGS)' github.com/k3d-io/k3d/v5@$(K3D_VERSION)
	GOBIN=$(GOBIN) go install github.com/kyverno/chainsaw@$(CHAINSAW_VERSION)
	dir=$$(cd / && go mod download -json github.com/helmfile/helmfile@$(HELMFILE_VERSION) | jq -r .Dir) && [ -n "$$dir" ] && \
		cd "$$dir" && GOBIN=$(GOBIN) go install -ldflags='-X go.szostok.io/version.version=$(HELMFILE_VERSION)' .

# Refuses anything but Linux x86_64: the Helm it installs is the linux-amd64 build, and GOBIN comes first on PATH, so on
# a Mac it would shadow Homebrew's helm and break every helm call with "exec format error".
ci-tools: ## CI only (Linux amd64): install buf and Helm at the pinned versions into GOBIN (a dev machine uses Homebrew)
	@[ "$$(uname -sm)" = "Linux x86_64" ] || { echo "make ci-tools runs only on Linux x86_64 (CI), not on \
	$$(uname -sm): a dev machine installs buf and Helm with Homebrew" >&2; exit 1; }
	GOBIN=$(GOBIN) go install github.com/bufbuild/buf/cmd/buf@$(BUF_VERSION)
	@tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	curl -fsSL -o "$$tmp/helm.tar.gz" https://get.helm.sh/helm-$(HELM_VERSION)-linux-amd64.tar.gz || exit 1; \
	echo "$(HELM_LINUX_AMD64_SHA256)  $$tmp/helm.tar.gz" | sha256sum -c - || exit 1; \
	tar -xzf "$$tmp/helm.tar.gz" -C "$$tmp" linux-amd64/helm || exit 1; \
	install -m 755 "$$tmp/linux-amd64/helm" $(GOBIN)/helm

generate: generate-go ## Generate all code (generate-go)

generate-go: ## Generate Go code from proto/ (buf) and from SQL (sqlc, per service)
	buf generate
	@for f in $(wildcard services/*/sqlc.yaml); do echo "sqlc generate -f $$f"; sqlc generate -f $$f || exit 1; done

# Runs generate-go in a scratch copy of the files git tracks plus the untracked ones it does not ignore (so .env is
# never read) and compares the result with a second, untouched copy: the working tree is never written, so uncommitted
# edits of generated code survive, and a file that generation adds counts as a difference too. A tracked file deleted
# from the working tree is left out of both copies.
generate-check: ## Fail when make generate-go would change or add a file: list them and print the diff (writes nothing here)
	@tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	git ls-files -z -co --exclude-standard > "$$tmp/listed" || exit 1; \
	xargs -0 sh -c 'for f; do if [ -e "$$f" ] || [ -L "$$f" ]; then printf "%s\0" "$$f"; fi; done' sh \
		< "$$tmp/listed" > "$$tmp/files" || exit 1; \
	COPYFILE_DISABLE=1 tar -cf "$$tmp/tree.tar" --null -T "$$tmp/files" || exit 1; \
	mkdir "$$tmp/before" "$$tmp/after" && tar -xf "$$tmp/tree.tar" -C "$$tmp/before" \
		&& tar -xf "$$tmp/tree.tar" -C "$$tmp/after" || exit 1; \
	$(MAKE) --no-print-directory -C "$$tmp/after" generate-go || exit 1; \
	cd "$$tmp" || exit 1; \
	if git diff --no-index --quiet before after; then echo "generated code is up to date"; exit 0; fi; \
	echo "make generate-go changes or adds these files (run make generate-go and commit the result):"; \
	git -c core.quotepath=off diff --no-index --no-color --no-ext-diff --name-status before after; \
	git -c core.quotepath=off diff --no-index --no-color --no-ext-diff before after; \
	exit 1

slo: ## Generate the SLO recording and burn-rate alert rules from deploy/observability/slo/svp-slos.yaml (Sloth)
	sloth generate --no-color -i deploy/observability/slo/svp-slos.yaml -o deploy/observability/prometheus/rules/slo-generated.yaml

# The Collector image of `otelcol` and `otelcol-elastic` in deploy/compose/compose.yaml and of
# base/otel-collector.yaml of svp-gitops (keep the four in step), run with no network and the config
# files at the paths compose mounts them.
# renovate: datasource=docker depName=otel/opentelemetry-collector-contrib
OTELCOL_IMAGE := otel/opentelemetry-collector-contrib:0.164.0@sha256:340c9ca6a36617084c6661bdc4f0fe92b7cda5a805d61673ec8db375fddc522b
# The config reads the Kafka scraper's broker, password and CA, and on EKS the region, workspace and log group, from the
# environment, with no default (a default would hide a missing setting); validate needs placeholders only, since it
# reaches nothing.
OTELCOL := env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none \
	-e SVP_KAFKA_OTELCOL_PASSWORD=validate -e SVP_OTELCOL_KAFKA_BROKERS=kafka:9096 -e SVP_OTELCOL_KAFKA_CA_FILE= \
	-e SVP_OTELCOL_REGION=ap-southeast-1 -e SVP_OTELCOL_LOG_GROUP=/svp/validate/otel \
	-e SVP_OTELCOL_AMP_ENDPOINT=https://aps-workspaces.ap-southeast-1.amazonaws.com/workspaces/ws-validate/ \
	-v $(CURDIR)/deploy/observability/otelcol/config.yaml:/etc/otelcol/config.yaml:ro \
	-v $(CURDIR)/deploy/observability/elastic/otelcol-config.yaml:/etc/otelcol/elastic.yaml:ro \
	-v $(CURDIR)/deploy/observability/otelcol/k8s-config.yaml:/etc/otelcol/k8s.yaml:ro \
	-v $(CURDIR)/deploy/observability/otelcol/k8s-k3d.yaml:/etc/otelcol/k8s-k3d.yaml:ro \
	-v $(CURDIR)/deploy/observability/otelcol/k8s-eks.yaml:/etc/otelcol/k8s-eks.yaml:ro \
	$(OTELCOL_IMAGE)
# A SigV4 extension fetches credentials when it is checked, which needs a network or credentials. For validate only,
# each reads a web identity from a file instead (any file, a made-up role), which fetches nothing until a request.
OTELCOL_WEB_IDENTITY := {assume_role: {arn: validate, web_identity_token_file: /etc/otelcol/k8s-eks.yaml}}
OTELCOL_SIGV4_OFFLINE := yaml:extensions: {sigv4auth/aps: $(OTELCOL_WEB_IDENTITY), \
	sigv4auth/logs: $(OTELCOL_WEB_IDENTITY), sigv4auth/xray: $(OTELCOL_WEB_IDENTITY)}

otelcol-validate: ## Validate the Collector configs with the pinned Collector: obs, obs-elastic (the obs file with the Elastic file merged over it) and the cluster's (k8s-config.yaml with each platform's destination file merged over it)
	$(OTELCOL) validate --config=/etc/otelcol/config.yaml
	$(OTELCOL) validate --config=/etc/otelcol/config.yaml --config=/etc/otelcol/elastic.yaml
	$(OTELCOL) validate --config=/etc/otelcol/k8s.yaml --config=/etc/otelcol/k8s-k3d.yaml
	$(OTELCOL) validate --config=/etc/otelcol/k8s.yaml --config=/etc/otelcol/k8s-eks.yaml --config='$(OTELCOL_SIGV4_OFFLINE)'

fmt-check: ## Fail and list the files that gofmt would change (generated code excluded)
	@out=$$(find . -name '*.go' -not -path './gen/*' -not -path './.roster/*' -print0 \
		| xargs -0 grep -L --null '^// Code generated .* DO NOT EDIT\.$$' | xargs -0 gofmt -l) \
		|| { echo "gofmt failed (syntax error?)" >&2; exit 1; }; \
	if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

vet: ## go vet
	go vet $(PKGS)

lint: ## golangci-lint run (LINTFLAGS adds flags)
	golangci-lint run $(LINTFLAGS) $(PKGS)

actionlint: ## Lint every workflow of .github/workflows (actionlint)
	@command -v actionlint >/dev/null 2>&1 || { echo "actionlint not found: run make tools" >&2; exit 1; }
	actionlint

buf-lint: ## buf lint and buf build
	buf lint
	buf build -o /dev/null

# The go directive of go.mod is the Go release of the images: govulncheck scans the standard library of exactly that
# release, and tools/vulngate fails when a golang build stage of deploy/docker/ uses another one, so the result holds
# for the released binaries. govulncheck exits 0 in JSON mode whatever it finds: the gate decides. The output goes to a
# file, not a pipe, so a failure of govulncheck itself (no network to vuln.go.dev, a build error) fails the target too.
vulncheck: ## govulncheck ./... with the Go of the go directive; called vulnerabilities fail unless excepted in .govulncheck-ignore.json
	@command -v govulncheck >/dev/null 2>&1 || { echo "govulncheck not found: run make tools" >&2; exit 1; }
	@gover=$$(go list -m -f '{{.GoVersion}}') || exit 1; \
	case "$$gover" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "the go directive of go.mod must name a patch release \
	(go 1.27.3), not go $$gover" >&2; exit 1;; esac; \
	tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	GOTOOLCHAIN=go$$gover govulncheck -format json ./... > "$$tmp/vuln.json" \
		|| { echo "govulncheck failed (exit $$?): see the error above" >&2; exit 1; }; \
	go run ./tools/vulngate $(wildcard deploy/docker/*.Dockerfile) < "$$tmp/vuln.json"

test: ## go test -race (SVP_TEST_POSTGRES_URL and SVP_TEST_REDIS_URL default to the local Postgres and Redis db 15; TESTFLAGS adds flags, e.g. TESTFLAGS=-count=1)
	SVP_TEST_POSTGRES_URL='$(SVP_TEST_POSTGRES_URL)' SVP_TEST_REDIS_URL='$(SVP_TEST_REDIS_URL)' go test -race $(TESTFLAGS) $(PKGS)

cover: ## go test -race with coverage into cover.out (same test variables and TESTFLAGS as test), print the total
	SVP_TEST_POSTGRES_URL='$(SVP_TEST_POSTGRES_URL)' SVP_TEST_REDIS_URL='$(SVP_TEST_REDIS_URL)' go test -race -coverprofile=cover.out $(TESTFLAGS) $(PKGS)
	@go tool cover -func=cover.out | tail -1
	@echo "per line in a browser: go tool cover -html=cover.out"

# How long `make fuzz` fuzzes each target.
FUZZTIME ?= 30s

# go test -fuzz takes one target of one package per run. Targets are found by reading the *_test.go files, not with
# go test -list: listing runs TestMain, and a TestMain may build a database. No -race: it slows fuzzing down several
# times, and make test already runs every seed with -race. A failing input goes to testdata/fuzz/<target>/ of its
# package, to be fixed and committed so the seeds keep it.
fuzz: ## Fuzz each Fuzz target of PKGS for FUZZTIME (default 30s), one at a time; stop at the first failure and print its input
	@list=$$(go list -f '{{.ImportPath}} {{.Dir}}' $(PKGS)) || exit 1; \
	targets=$$(printf '%s\n' "$$list" | while read -r pkg dir; do \
		for file in "$$dir"/*_test.go; do [ -f "$$file" ] && sed -nE 's/^func (Fuzz[A-Za-z0-9_]*)\(.*/\1/p' "$$file"; done \
			| sort -u | sed "s|^|$$pkg $$dir |"; \
	done); \
	[ -n "$$targets" ] || { echo "no Fuzz targets in $(PKGS)" >&2; exit 1; }; \
	tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	printf '%s\n' "$$targets" | while read -r pkg dir target; do \
		echo "== $$target ($$pkg) for $(FUZZTIME)"; touch "$$tmp/start"; \
		SVP_TEST_POSTGRES_URL='$(SVP_TEST_POSTGRES_URL)' SVP_TEST_REDIS_URL='$(SVP_TEST_REDIS_URL)' \
			go test -run '^$$' -fuzz "^$$target\$$" -fuzztime $(FUZZTIME) "$$pkg" < /dev/null && continue; \
		echo "fuzz failed: $$target in $$pkg" >&2; \
		find "$$dir/testdata/fuzz/$$target" -type f -newer "$$tmp/start" 2>/dev/null | sed 's|^|failing input: |' >&2; \
		exit 1; \
	done

check: check-go ## Run every check (check-go)

check-go: fmt-check vet lint actionlint buf-lint vulncheck test ## Run the Go, workflow and proto checks

# The charts run against the deployment configuration of the clone of svp-gitops that gitops_dir of deploy/k8s/lib.sh
# names (../gitops beside the main checkout, or SVP_GITOPS_DIR, which CI points at the clone of make gitops-clone).
# Needs Docker and network access to the chart repositories. A change that needs a new value in base/ merges in
# svp-gitops first, then here.
helm-check: helm-docs-check ## helm lint and helm template every chart of the working tree with base/ of the clone of svp-gitops (../gitops, or SVP_GITOPS_DIR) alone and with the overlays and image files of each environment, its root chart argocd/apps for each environment on amd64 and arm64 nodes, the ExternalSecrets and SecretStores of each environment against the CRD schemas of the pinned External Secrets chart (kubeconform), and the Kyverno policies of deploy/ci/gitops-policies/ on the renders: every image pinned by digest, no svp.localhost on a real platform (deploy/ci/gitops-check.sh --worktree)
	@gitops=$$(bash -c '$(K8S_LIB) && gitops_dir') && \
	  KUBECONFORM_IMAGE='$(KUBECONFORM_IMAGE)' KYVERNO_CLI_IMAGE='$(KYVERNO_CLI_IMAGE)' \
	  deploy/ci/gitops-check.sh --worktree "$$gitops"

# README.md of chart svp-service is generated by helm-docs from Chart.yaml, the "# --" comments of values.yaml and
# README.md.gotmpl. It documents the values the seven releases' files in svp-gitops set, so it must not drift from
# values.yaml: helm-docs-check mounts the repository read-only, has helm-docs print what it would write (--dry-run) and
# fails when README.md differs; helm-check runs it.
# renovate: datasource=docker depName=jnorwood/helm-docs
HELM_DOCS_IMAGE := jnorwood/helm-docs:v1.14.2@sha256:7e562b49ab6b1dbc50c3da8f2dd6ffa8a5c6bba327b1c6335cc15ce29267979c
HELM_DOCS_CHART := deploy/helm/svp-service
HELM_DOCS = env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none --user "$$(id -u):$$(id -g)" \
	-v "$(CURDIR):/helm-docs$(1)" '$(HELM_DOCS_IMAGE)' --chart-search-root $(HELM_DOCS_CHART)
helm-docs: ## Write README.md of chart svp-service with the pinned helm-docs
	$(call HELM_DOCS,)
helm-docs-check: ## Fail when README.md of chart svp-service differs from what the pinned helm-docs generates
	@$(call HELM_DOCS,:ro) --dry-run | diff -u $(HELM_DOCS_CHART)/README.md - \
	  || { echo "$(HELM_DOCS_CHART)/README.md is out of date: run make helm-docs" >&2; exit 1; }

# The resources of deploy/ci/gitops-policies/test/<policy>/ that must fail and those that must pass, per policy. No
# cluster, no network.
kyverno-test: ## kyverno test of the policies on rendered manifests (deploy/ci/gitops-policies/, Kyverno CLI in KYVERNO_CLI_IMAGE, no network)
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" --network none \
	  -v "$(CURDIR)/deploy/ci/gitops-policies:/p:ro" '$(KYVERNO_CLI_IMAGE)' test /p --remove-color

# The unit tests of the conftest policies (*_test.rego beside them), one run per folder: the ignore-file policies of
# deploy/ci/scan-gate.sh (every file shape and rule that must fail, and those that must pass, with today fixed) and the
# tree policies of deploy/ci/gitops-check.sh (every rule that must fail and pass, on a tree written in the tests).
CONFTEST_POLICIES := deploy/ci/ignorefile-policies deploy/ci/gitops-tree-policies
conftest-verify: ## conftest verify of the ignore-file and svp-gitops tree policies (deploy/ci/*-policies/ of Rego, conftest in CONFTEST_IMAGE, no network)
	@set -e; for dir in $(CONFTEST_POLICIES); do \
	  echo "conftest verify $$dir"; \
	  env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" --network none \
	    -v "$(CURDIR)/$$dir:/p:ro" -w /p '$(CONFTEST_IMAGE)' verify --policy . --no-color; \
	done

# Regal over the same two folders, one run per folder like conftest (the packages of a folder see each other only).
# regal-lint only reads (a violation, a warning too, is exit 1); regal-fix writes the fixes Regal has (opa fmt and the
# rest of the list in `regal fix --help`) into the folders, the only place the container may write.
regal-lint: ## Regal lint of the Rego policies (deploy/ci/*-policies/, rules in .regal/config.yaml, Regal in REGAL_IMAGE, no network, read-only)
	@set -e; for dir in $(CONFTEST_POLICIES); do \
	  echo "regal lint $$dir"; \
	  env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" --network none --read-only \
	    -v "$(CURDIR)/$$dir:/p:ro" -v "$(CURDIR)/.regal:/regal:ro" -w /p '$(REGAL_IMAGE)' \
	    lint . --config-file /regal/config.yaml --fail-level warning --no-color; \
	done

# Every YAML file under CHAINSAW_DRILLS is exactly one of three things, and any other is an error (a file nothing checks
# is not a green one): chainsaw-test.yaml, .chainsaw.yaml, or a StepTemplate under templates/. chainsaw lint (v0.2.15)
# takes only test and configuration, so kubeconform -strict checks the templates against the schema of CHAINSAW_VERSION
# kept in .schemas/ (offline); it fails on a kind with no schema.
CHAINSAW_DRILLS := deploy/k8s/drills
chainsaw-lint: ## Lint the Chainsaw drills of deploy/k8s/drills/: chainsaw lint test and configuration, kubeconform -strict on the step templates, any other YAML file is an error (no cluster)
	@set -eu; d='$(CHAINSAW_DRILLS)'; rc=0; \
	grep -qF "/chainsaw/$(CHAINSAW_VERSION)/.schemas/json/steptemplate-chainsaw-v1alpha1.json" "$$d/.schemas/source" || { \
	  echo "FAIL  $$d/.schemas/source is not the schema of Chainsaw $(CHAINSAW_VERSION): copy it again from that tag and write its URL there" >&2; exit 1; }; \
	files=$$(find "$$d" -path "$$d/.schemas" -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print | LC_ALL=C sort); \
	for f in $$files; do \
	  case $$f in \
	    */chainsaw-test.yaml) kind=test ;; \
	    */.chainsaw.yaml) kind=configuration ;; \
	    "$$d"/templates/*) kind=steptemplate ;; \
	    *) echo "FAIL  $$f: not a chainsaw-test.yaml, a .chainsaw.yaml or a StepTemplate under $$d/templates/" >&2; rc=1; continue ;; \
	  esac; \
	  if [ $$kind = steptemplate ]; then \
	    out=$$(env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" --network none \
	      -v "$(CURDIR)/$$d:/drills:ro" '$(KUBECONFORM_IMAGE)' -strict -summary \
	      -schema-location /drills/.schemas/json/steptemplate-chainsaw-v1alpha1.json "/drills/$${f#$$d/}" 2>&1) || { \
	      echo "FAIL  $$f"; echo "$$out"; rc=1; continue; }; \
	  else \
	    out=$$(chainsaw lint $$kind -f "$$f" 2>&1) || { echo "FAIL  $$f"; echo "$$out"; rc=1; continue; }; \
	  fi; \
	  echo "ok    $$f ($$kind)"; \
	done; \
	exit $$rc

regal-fix: ## Regal fix of the Rego policies (opa fmt and the other automatic fixes; writes deploy/ci/*-policies/)
	@set -e; for dir in $(CONFTEST_POLICIES); do \
	  echo "regal fix $$dir"; \
	  env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" --network none --read-only \
	    -v "$(CURDIR)/$$dir:/p" -v "$(CURDIR)/.regal:/regal:ro" -w /p '$(REGAL_IMAGE)' \
	    fix . --config-file /regal/config.yaml --no-color; \
	done

# It only reports: exit 0 whatever it finds. The findings that are deliberate choices are left out by
# deploy/ci/trivy-config-ignore.yaml, each for its paths and until its expired_at, with the reason in the file. The
# report belongs to the caller (the container runs as them); the policy bundle trivy downloads goes to a cache inside
# the container.
TRIVY_CONFIG_SARIF ?=
trivy-config: ## trivy config on the repository, report only (TRIVY_CONFIG_SARIF=<absolute path> writes SARIF)
	@if [ -n "$(TRIVY_CONFIG_SARIF)" ]; then \
	  set -- -v "$$(dirname "$(TRIVY_CONFIG_SARIF)"):/out" $(TRIVY_IMAGE) config --format sarif \
		--output "/out/$$(basename "$(TRIVY_CONFIG_SARIF)")"; \
	else set -- $(TRIVY_IMAGE) config --format table; fi; \
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" -v "$(CURDIR):/src:ro" --workdir /src \
		"$$@" --quiet --cache-dir /tmp/trivy --ignorefile deploy/ci/trivy-config-ignore.yaml --exit-code 0 .

# deploy/ci/scan-gate.sh --grype runs grype on an SPDX SBOM with --fail-on critical and .grype.yaml (any Critical left
# after its rules fails). IMAGE=<ref>@sha256:<digest> [ARCH=amd64|arm64] first has the pinned syft read the image of
# that platform from its registry, anonymously. grype needs the network for its DB, and a DB it cannot fetch fails the
# target. SVP_GRYPE_CACHE, when set, keeps the DB in that directory (it is about 3 GB unpacked); unset, in $TMPDIR.
SBOM ?=
IMAGE ?=
ARCH ?= amd64
grype: ## grype + gate on an SBOM (SBOM=<absolute path of SPDX JSON>) or an image (IMAGE=<ref@sha256:...> [ARCH=amd64|arm64])
	@bash -c '. deploy/ci/common.sh && grype_check "$$1" "$$2" "$$3"' grype '$(SBOM)' '$(IMAGE)' '$(ARCH)'

# Checks renovate.json as the GitHub App reads it, a repository config (--no-global), and fails on any error or on an
# option that needs migrating (--strict). renovate.json must stay readable by the image's uid 12021. The App runs the
# Renovate version Mend deploys, which can lag this one by up to a week.
# renovate: datasource=docker depName=ghcr.io/renovatebot/renovate
RENOVATE_IMAGE := ghcr.io/renovatebot/renovate:44.165.1@sha256:455f4169a364a4c8bdc38a08694e3509649f3d7cb9aaea35c86946b38015ac47
renovate-check: ## Validate renovate.json with the pinned Renovate (renovate-config-validator --strict, no network)
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$(CURDIR):/repo:ro" --workdir /repo \
		$(RENOVATE_IMAGE) renovate-config-validator --strict --no-global renovate.json

# Every finding fails (exit codes 11 to 14); the deliberate ones are left out in .github/zizmor.yml, each with its
# reason. With GH_TOKEN set (CI passes the job's read-only GITHUB_TOKEN) the online audits run too (impostor commits,
# actions with known vulnerabilities); without it, offline audits only. ZIZMOR_SARIF=<path> writes a SARIF report there
# instead and never fails on a finding (the report of the code scanning upload).
# renovate: datasource=docker depName=ghcr.io/zizmorcore/zizmor
ZIZMOR_IMAGE := ghcr.io/zizmorcore/zizmor:1.31.1@sha256:42d409dbb851d4c5d35a058cf042b828bea1e3f2884378c526eb0974780e18d9
ZIZMOR_FORMAT ?= plain
ZIZMOR_SARIF ?=
zizmor: ## Security lint of the workflows with the pinned zizmor (online audits with GH_TOKEN; ZIZMOR_FORMAT=github, ZIZMOR_SARIF=<path>)
	@if [ -n "$${GH_TOKEN:-}" ]; then net="--env=GH_TOKEN"; else net="--env=ZIZMOR_OFFLINE=true --network=none"; fi; \
	if [ -n "$(ZIZMOR_SARIF)" ]; then set -- --format=sarif --no-exit-codes; else set -- --format='$(ZIZMOR_FORMAT)'; fi; \
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" $$net -v "$(CURDIR):/src:ro" --workdir /src \
		$(ZIZMOR_IMAGE) --persona=regular --no-progress --color=never --cache-dir /tmp/zizmor "$$@" . \
		$(if $(ZIZMOR_SARIF),> '$(ZIZMOR_SARIF)')

# lychee --offline checks relative links and heading anchors; links to other sites are not followed: the network is not
# stable and a check that depends on it fails for reasons outside the change. The repository is mounted at /repo, so a
# relative link that leaves it (to plans/, which is no repository's) is an error on purpose. Both tools always run; the
# exit code is not 0 when either reports a problem.
# renovate: datasource=docker depName=davidanson/markdownlint-cli2
MARKDOWNLINT_IMAGE := davidanson/markdownlint-cli2:v0.24.0@sha256:70ead7c0352d22d04bbe612cd96b54ec591538d8f4626cafe391bb2ecf3639ca
# renovate: datasource=docker depName=lycheeverse/lychee
LYCHEE_IMAGE := lycheeverse/lychee:0.24.2@sha256:e2d19e57cf6ab037026f20b8e449a1f30d9d7f81eef4194763aab2eab20bd28d
# set -f keeps the globs of DOCS whole: the tools expand them (with **), sh does not and would drop the files at the top.
DOCS ?=
docs-check: ## markdownlint-cli2 + lychee --offline on the Markdown (DOCS='<files or globs>' narrows; pinned images, no network)
	@if [ -n '$(DOCS)' ]; then set -f; set -- $(DOCS); set +f; \
	else set --; for f in $$(git ls-files --cached --others --exclude-standard '*.md'); do [ -f "$$f" ] && set -- "$$@" "$$f"; done; fi; \
	rc=0; \
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$(CURDIR):/repo:ro" --workdir /repo \
		$(MARKDOWNLINT_IMAGE) "$$@" || rc=1; \
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$(CURDIR):/repo:ro" --workdir /repo \
		$(LYCHEE_IMAGE) --offline --include-fragments "$$@" || rc=1; \
	exit $$rc

# The version rule of services/gateway/openapi.yaml (written at the top of that file) against the spec at commit BASE:
# the file changed means info.version went up, a breaking change from 1.0.0 on means the major did, any entry in
# oasdiff's changelog means at least the minor did. CI passes the base of the pull request, as for buf breaking.
BASE ?= origin/main
api-contract-check: ## Check the version rule of the gateway's OpenAPI spec against BASE (default origin/main) with the pinned oasdiff
	deploy/ci/contract.sh check "$(BASE)"

hooks: ## Point git at .githooks (run once per clone)
	git config core.hooksPath .githooks

# Each target runs the target of svp-frontend its help names, in the clone web_dir of deploy/k8s/lib.sh names
# (<workspace>/frontend, or SVP_WEB_DIR), with that clone's Node, pnpm and Playwright browsers, against this checkout's
# stack, scripts and .env (SVP_BACKEND_DIR). LOCAL LAB ONLY: the e2e seed and every Playwright worker, measure-upload
# and Lighthouse delete the gateway's register rate limit keys in Valkey db 10, as make smoke does.
IN_WEB = dir=$$(bash -c '$(K8S_LIB) && web_dir') && SVP_BACKEND_DIR='$(CURDIR)' $(MAKE) --no-print-directory -C "$$dir"

web-e2e: ## Playwright end-to-end tests of the web client on Chromium and WebKit against the stack of make up (make e2e of svp-frontend)
	@$(IN_WEB) e2e

measure-web: ## Run the web client's e2e tests and print time to first frame after a swipe (p50/p95 per browser) and the memory of container web at rest and after (make measure-web of svp-frontend)
	@$(IN_WEB) measure-web

measure-upload: ## Upload a ~100 MB video from Chromium through /upload; print time, throughput, page CPU and time to READY; needs ffmpeg and jq (make measure-upload of svp-frontend)
	@$(IN_WEB) measure-upload

web-lighthouse: ## Lighthouse (mobile, one run per page) of the feed logged in and /v/{id} logged out: LCP/CLS/TBT thresholds (make lighthouse of svp-frontend)
	@$(IN_WEB) lighthouse

# Only for a web client built from that clone (make up WEB_FROM=clone OBS=lgtm): a release keeps the build id CI gave
# it, and its maps come from CI.
web-sourcemaps: ## Upload the source maps of the web client's browser bundle, from the build the stack of make up OBS=lgtm WEB_FROM=clone runs, to its GlitchTip (http://127.0.0.1:8000); checks first that the web serves that build (make sourcemaps of svp-frontend)
	@$(IN_WEB) sourcemaps

-include deploy/compose/compose.mk
-include deploy/k8s/k8s.mk
-include deploy/k6/k6.mk
-include deploy/dast/dast.mk
