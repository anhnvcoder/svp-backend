# Local Kubernetes targets (k3d cluster svp), included by the root Makefile, and the eks-* targets for an EKS cluster
# of the project (at the end). docker and k3d run without DOCKER_DEFAULT_PLATFORM and kubectl/helm always name their
# context, --context k3d-svp on every target but eks-*; the shell helpers behind these targets are in deploy/k8s/lib.sh.

K8S_LIB := . deploy/k8s/lib.sh

.PHONY: k8s-exclusive k8s-up k8s-down k8s-status k8s-ca k8s-secrets k8s-images k8s-smoke \
	k8s-glitchtip-init k8s-ui-grafana k8s-ui-prometheus k8s-ui-alertmanager k8s-ui-glitchtip k8s-gitops-up \
	k8s-ui-argocd k8s-traffic-start k8s-traffic-stop drill-k8s-threats \
	drill-k8s-supplychain k8s-web-sourcemaps k8s-web-e2e cloud-check \
	gitops-clone web-clone eks-gitops-up eks-secrets eks-glitchtip-init eks-smoke eks-seed \
	eks-rl-reset

# Compose and k3d never run together on the 16 GB machine (CLAUDE.md): the cluster is not created or started beside a
# running compose stack. `make up` refuses the other way round (deploy/compose/compose.mk).
k8s-exclusive:
	@running=$$(env -u DOCKER_DEFAULT_PLATFORM docker compose -p svp ps -q); \
	  if [ -n "$$running" ]; then echo "make k8s-up: the compose stack svp is running; run 'make down' first" >&2; exit 1; fi

# env-required: the Secrets come from .env (deploy/k8s/secrets.sh, run by install.sh once the namespaces exist). The
# clone of svp-gitops is looked up first (gitops_dir), so a missing one stops the target before anything is created.
# install.sh refuses a cluster made while the object store was MinIO (StatefulSet svp-data/minio): such a cluster is
# made again, never upgraded in place.
# WEB_FROM and WEB_IMAGE choose the web client as for make up (deploy/compose/compose.mk): its release in staging by
# default, or WEB_IMAGE (both pulled from GHCR, anonymously by the nodes; the image policy only audits on this path),
# or built from the clone of svp-frontend with WEB_FROM=clone. The six backend services are always built here: IMAGES is
# make up's alone.
k8s-up: k8s-exclusive env-required ## Create (or start) the registry 127.0.0.1:5111 and cluster svp (API 127.0.0.1:6550, HTTPS 127.0.0.1:8443), build and push the six backend images (WEB_FROM=clone: the web client's too, from the clone of svp-frontend, ../frontend or SVP_WEB_DIR; otherwise the web client runs its staging release, or WEB_IMAGE=<ghcr.io/...@sha256:...> with WEB_FROM=image), install argocd/apps/components.json of the clone of svp-gitops (../gitops beside the checkout, or SVP_GITOPS_DIR) with its base/ values, with drill traffic while a canary of the gateway or the web client runs; idempotent; refuses a cluster still running MinIO (make k8s-down first) (LOCAL LAB ONLY: a canary's drill traffic resets register rate limit keys in the cluster's Valkey db 10)
	@test -z '$(IMAGES)' || { echo "make k8s-up: IMAGES=$(IMAGES) is a setting of make up only; the cluster of the dev path builds the six backend services" >&2; exit 1; }
	@WEB_FROM='$(WEB_FROM)' WEB_IMAGE='$(WEB_IMAGE)' bash -c '$(K8S_LIB) && gitops_dir >/dev/null && web_source && ensure_registry && ensure_cluster'
	WEB_FROM='$(WEB_FROM)' WEB_IMAGE='$(WEB_IMAGE)' deploy/k8s/install.sh

# The deployment configuration is the repository svp-gitops (deploy/k8s/lib.sh, gitops_dir): a machine reads its own
# clone, ../gitops beside the main checkout or SVP_GITOPS_DIR, which no target clones, fetches or switches. CI clones
# it with gitops-clone into .gitops/svp-gitops (gitignored) at GITOPS_REF and sets SVP_GITOPS_DIR there before any
# target that reads the configuration.
GITOPS_REF ?= main

gitops-clone: ## CI: clone svp-gitops anonymously into .gitops/svp-gitops (gitignored), or fetch it when it is there, and check out GITOPS_REF (default main, or a full commit SHA); refuses a clone there with uncommitted changes. A machine reads its own clone instead (../gitops beside the checkout, or SVP_GITOPS_DIR)
	@GITOPS_REF='$(GITOPS_REF)' bash -c '$(K8S_LIB) && gitops_clone'

# The web client's source, as the configuration: a machine reads its own clone (<workspace>/frontend, or SVP_WEB_DIR),
# CI clones it with web-clone into .web/svp-frontend (gitignored) and sets SVP_WEB_DIR there before any target that builds
# or tests the web. WEB_REF unset is the commit of the web release in staging (image.tag of envs/stg/images/web.yaml in
# the clone of svp-gitops), so the tests run the code staging runs.
WEB_REF ?=

web-clone: ## CI: clone svp-frontend anonymously into .web/svp-frontend (gitignored), or fetch it when it is there, and check out WEB_REF (a branch or a full commit SHA; unset: the commit of the web release in staging); refuses a clone there with uncommitted changes. Then set SVP_WEB_DIR to that folder; a machine reads its own clone instead (../frontend beside the checkout, or SVP_WEB_DIR)
	@WEB_REF='$(WEB_REF)' bash -c '$(K8S_LIB) && web_clone'

# The GitOps path: a new cluster svp that Argo CD builds from GitHub, running the release images of GHCR, as the
# staging environment: base/ of svp-gitops plus the overlays and release images of its envs/stg, with the charts of this
# repository at the commit envs/stg/charts.yaml pins (production is only rendered, by the checks). GITOPS_REV is the
# revision of svp-gitops Argo CD follows: a branch of the clone's origin (read from origin/<branch> as last fetched) or a
# full commit SHA. The cluster is built at the commit checked (the root and every values source read that SHA); given a
# branch, the root then moves to refs/heads/<branch> once the cluster is built, given a SHA it stays there. Releases
# are built, signed and promoted by CI (.github/workflows/images.yml): no target builds one on this machine. Argo CD
# reads both public repositories over HTTPS without credentials: no deploy key, no secret.
GITOPS_REV ?= main

k8s-gitops-up: k8s-exclusive env-required ## Create a new cluster svp that runs as staging (base/ plus envs/stg of svp-gitops), built by Argo CD from GitHub over anonymous HTTPS (no deploy key) [GITOPS_REV=main, a branch of the clone of svp-gitops or a commit]; first checks that the seven release digests of envs/stg/images/ at that revision are on GHCR (anonymous pull), signed, with a clean vuln attestation at most 48 h old; applies the Secrets of .env, installs Argo CD with the plugin of Argo Rollouts for the nodes' architecture, waits until every Application is Synced and Healthy
	SVP_KUBE_CONTEXT=k3d-svp GITOPS_REV='$(GITOPS_REV)' deploy/k8s/gitops.sh

k8s-down: ## Delete cluster svp and its registry (compose volumes and the host's Postgres are not touched)
	@if env -u DOCKER_DEFAULT_PLATFORM k3d cluster get svp >/dev/null 2>&1; then \
	  env -u DOCKER_DEFAULT_PLATFORM k3d cluster delete svp; else echo "cluster svp not found"; fi
	@if env -u DOCKER_DEFAULT_PLATFORM docker inspect k3d-svp-registry >/dev/null 2>&1; then \
	  env -u DOCKER_DEFAULT_PLATFORM k3d registry delete svp-registry; else echo "registry k3d-svp-registry not found"; fi

k8s-status: ## Show the containers, nodes and the pods of every namespace but kube-system of cluster svp
	@env -u DOCKER_DEFAULT_PLATFORM docker ps -a --filter name=k3d-svp --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
	@if env -u DOCKER_DEFAULT_PLATFORM k3d cluster get svp >/dev/null 2>&1; then \
	  kubectl --context k3d-svp get nodes -o wide && \
	  kubectl --context k3d-svp get pods --all-namespaces --field-selector metadata.namespace!=kube-system; \
	else echo "cluster svp not found; run make k8s-up"; fi

k8s-secrets: env-required ## Create or update the cluster's Secrets from .env (no value printed; a changed Redpanda admin password needs redpanda-0 running), restart the object store or Redpanda if their password changed; then run make k8s-up: the init Jobs set the new passwords and each service whose Secret changed restarts with them (on the GitOps cluster: the steps at the top of deploy/k8s/gitops.sh). On a cluster with namespace svp-secrets (GitOps staging with External Secrets) it writes only the source Secrets there and has every ExternalSecret built again from them
	SVP_KUBE_CONTEXT=k3d-svp deploy/k8s/secrets.sh

# Needs no .env: both values are GlitchTip's own, read inside its pod (deploy/k8s/glitchtip-init.sh).
k8s-glitchtip-init: ## Put GlitchTip's DSN into Secret svp/sentry and its read-only API token into Secret svp-obs/glitchtip-api (never into .env, nothing printed), then restart each service whose pods started without the current DSN; idempotent, run by make k8s-up
	SVP_KUBE_CONTEXT=k3d-svp deploy/k8s/glitchtip-init.sh

k8s-ca: ## Write the CA of the cluster's TLS certificates to .k8s/ca.crt (curl --cacert .k8s/ca.crt https://<name>.svp.localhost:8443/)
	@bash -c '$(K8S_LIB) && export_ca'

# The dev tags depend only on the images' content (deploy/k8s/lib.sh, build_dev_images), so this target and the build
# inside `make k8s-up` give the same tags for the same working tree.
k8s-images: ## Build the seven service images from the working tree (the web client's from the clone of svp-frontend) and push them to the registry 127.0.0.1:5111 as svp/<service>:dev-<image ID>
	@bash -c '$(K8S_LIB) && ensure_registry && build_dev_images'

# deploy/compose/smoke.sh through Envoy: curl trusts the cluster's CA for api.svp.localhost and s3.svp.localhost (both
# resolve to loopback), and the register rate limit is reset in the cluster's Valkey (SVP_STACK=k3d).
k8s-smoke: ## Run the end-to-end smoke test against cluster svp at https://api.svp.localhost:8443 (CA .k8s/ca.crt; LOCAL LAB ONLY: deletes the register rate limit keys in the cluster's Valkey db 10)
	@test -s .k8s/ca.crt || { echo "make k8s-smoke: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)" >&2; exit 1; }
	SVP_STACK=k3d CURL_CA_BUNDLE=$(CURDIR)/.k8s/ca.crt deploy/compose/smoke.sh https://api.svp.localhost:8443

# Drills on cluster svp (deploy/k8s/drills/), through Envoy like k8s-smoke.
K8S_DRILL_ENV := SVP_STACK=k3d CURL_CA_BUNDLE=$(CURDIR)/.k8s/ca.crt

# The canaries of the gateway and the web client. The drill traffic runs in the background until stopped, for hours
# if need be (through the push of a release on the GitOps cluster); `make k8s-up` starts and stops its own while a
# canary of either is in progress.
k8s-traffic-start: ## Start drill traffic in the background: 4 users, ~10 requests/s to GET /feed/explore and /feed/following through https://api.svp.localhost:8443, and ~4 requests/s to the web client at https://svp.localhost:8443 (GET /login, one /_next/static asset), each request logged in .k8s/drills/traffic-<time>.log (LOCAL LAB ONLY: resets register rate limit keys in the cluster's Valkey db 10)
	@test -s .k8s/ca.crt || { echo "make k8s-traffic-start: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)" >&2; exit 1; }
	@$(K8S_DRILL_ENV) deploy/k8s/drills/traffic.sh start

k8s-traffic-stop: ## Stop the drill traffic started by k8s-traffic-start (the pid it recorded, nothing else) and print its requests by status
	@deploy/k8s/drills/traffic.sh stop

# The stage 4 rows of the threat model (docs/threat-model.md, section 5): the checks of each item are listed at the top
# of deploy/k8s/drills/threats.sh.
drill-k8s-threats: ## Check the stage 4 threat model rows on cluster svp, each with a control case: a probe pod in namespace svp-probe (created, then deleted) and media-worker reach only what the NetworkPolicies allow, Kafka ACLs per user, pod security and PSA, no trust in pg_hba, login rate limit ignores forged X-Forwarded-For, no pprof/metrics, no exposed UI, Grafana 401, no ServiceAccount reads secrets or pods; web client: no token or JWT in pages, RSC or /api JSON and /api/ outside the BFF list 400/404 (WEB-7), cross-site or same-site POSTs 403 CSRF_REJECTED (WEB-2), the object store's CORS per bucket for https://svp.localhost:8443 only, POST to uploads and GET at media only (WEB-10), web pods reach only gateway, Valkey, Collector, GlitchTip (WEB-13), login rate limit through the /login form counts the address Envoy wrote (WEB-8); object store user svp-pg-backup reads only bucket pg-backups and no service's user reads it (BAK-1); on a cluster with External Secrets Operator: each store's ServiceAccount gets only its namespace's source Secrets by name (SEC-6), the controller writes Secrets only where its ExternalSecrets are and makes tokens only for the stores (SEC-5, its read of every Secret printed as an exception), no ServiceAccount of svp creates ExternalSecrets or SecretStores (SEC-7); PASS/FAIL table, log in .k8s/drills/threats-<time>.log, searched for the Secret values read (LOCAL LAB ONLY: resets register rate limit keys in the cluster's Valkey db 10)
	@test -s .k8s/ca.crt || { echo "make drill-k8s-threats: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)" >&2; exit 1; }
	$(K8S_DRILL_ENV) deploy/k8s/drills/threats.sh https://api.svp.localhost:8443

# The image policy of namespace svp; the cases are listed at the
# top of deploy/k8s/drills/supplychain.sh. It talks to the cluster's API, and for the CRITICAL case and the case without
# provenance to GHCR and Sigstore through cosign (anonymous, COSIGN_IMAGE when cosign is not installed), so it needs
# neither .k8s/ca.crt nor the gateway, and deletes no rate limit key.
drill-k8s-supplychain: ## Check Kyverno's image policy of namespace svp: a signed, clean release admitted; unsigned (SUPPLYCHAIN_UNSIGNED=<GHCR digest>; SUPPLYCHAIN_UNSIGNED_FALLBACK=<GHCR digest> is used instead when Kyverno admits the first), CRITICAL (SUPPLYCHAIN_VULNERABLE=<GHCR digest>, attestation within the maximum age), outside GHCR, without digest, attestation too old, ephemeral container and image UPDATE refused, a release without build provenance (SUPPLYCHAIN_NO_PROVENANCE=<GHCR digest>, its vuln attestation within the maximum age) refused when the running policy checks provenance, each with its rule's message; Kyverno down refuses svp only; PASS/FAIL per case, JSON in .k8s/drills/ (dev path, whose policy is Audit: SUPPLYCHAIN_ENFORCE_TMP=1 switches it to Enforce for the drill and back)
	SVP_STACK=k3d SUPPLYCHAIN_UNSIGNED='$(SUPPLYCHAIN_UNSIGNED)' SUPPLYCHAIN_VULNERABLE='$(SUPPLYCHAIN_VULNERABLE)' \
	  SUPPLYCHAIN_UNSIGNED_FALLBACK='$(SUPPLYCHAIN_UNSIGNED_FALLBACK)' SUPPLYCHAIN_NO_PROVENANCE='$(SUPPLYCHAIN_NO_PROVENANCE)' \
	  SUPPLYCHAIN_ENFORCE_TMP='$(SUPPLYCHAIN_ENFORCE_TMP)' \
	  deploy/k8s/drills/supplychain.sh

# The operations UIs have no route, LoadBalancer or NodePort (threat model OPS-2): each is reached by a port-forward
# bound to the host's loopback only, for as long as the target runs (Ctrl-C ends it). The host ports are those of
# compose, so links such as an alert's "Source" (Prometheus' external URL, Grafana's datasource proxy on 3000) open
# the same way.
K8S_PORT_FORWARD := kubectl --context k3d-svp -n svp-obs port-forward --address 127.0.0.1

k8s-ui-grafana: ## Open Grafana of cluster svp on http://127.0.0.1:3000 (port-forward, loopback only; log in as admin with SVP_GRAFANA_ADMIN_PASSWORD of .env)
	$(K8S_PORT_FORWARD) service/kps-grafana 3000:80

k8s-ui-prometheus: ## Open Prometheus of cluster svp on http://127.0.0.1:9090 (port-forward, loopback only; Prometheus has no login, so it stays closed while the forward is not running)
	$(K8S_PORT_FORWARD) service/kps-prometheus 9090:9090

k8s-ui-alertmanager: ## Open Alertmanager of cluster svp on http://127.0.0.1:9093 (port-forward, loopback only; Alertmanager has no login, so it stays closed while the forward is not running)
	$(K8S_PORT_FORWARD) service/kps-alertmanager 9093:9093

k8s-ui-glitchtip: ## Open GlitchTip of cluster svp on http://127.0.0.1:8000 (port-forward, loopback only; log in with GLITCHTIP_ADMIN_EMAIL and GLITCHTIP_ADMIN_PASSWORD of .env)
	$(K8S_PORT_FORWARD) service/glitchtip 8000:8000

# The web image's source maps and the web client's end-to-end tests against cluster svp are code of svp-frontend too: each
# target runs the target of svp-frontend its help names in the clone web_dir names, as the web targets of the Makefile do
# (IN_WEB), against this checkout's cluster, .k8s/ca.crt and scripts (deploy/observability/glitchtip/sourcemaps.sh).
# The maps are built from that clone with the build id make k8s-up WEB_FROM=clone gave the image (web_build_id of
# deploy/k8s/lib.sh), checked against the chunks https://svp.localhost:8443 serves, and uploaded through a
# port-forward of its own on 127.0.0.1:8000, closed at the end. The e2e tests check .k8s/ca.crt and the
# cluster, set SVP_STACK=k3d and the CA for curl and Node, and with SVP_E2E_GLITCHTIP=1 also run the browser error
# test with the read-only token of Secret svp-obs/glitchtip-api and a port-forward of their own on 127.0.0.1:8000.
# SVP_E2E_EVIDENCE as for web-e2e.
k8s-web-sourcemaps: ## Upload the source maps of the web client's browser bundle, from the build cluster svp runs (dev path, make k8s-up WEB_FROM=clone), to its GlitchTip with the token of Secret svp-obs/glitchtip-sourcemaps; checks first that the web serves that build (port 127.0.0.1:8000 must be free) (make k8s-sourcemaps of svp-frontend)
	@$(IN_WEB) k8s-sourcemaps

k8s-web-e2e: ## Playwright end-to-end tests of the web client on Chromium and WebKit against cluster svp at https://svp.localhost:8443 (CA .k8s/ca.crt); SVP_E2E_GLITCHTIP=1 adds the browser error to GlitchTip check (needs make k8s-web-sourcemaps first, port 127.0.0.1:8000 free); SVP_E2E_EVIDENCE=<absolute folder> as for web-e2e (make k8s-e2e of svp-frontend; LOCAL LAB ONLY: deletes the register rate limit keys in the cluster's Valkey db 10)
	@$(IN_WEB) k8s-e2e

k8s-ui-argocd: ## Open Argo CD of the GitOps cluster on https://127.0.0.1:8081 (port-forward, loopback only; its own self-signed certificate; log in as admin, password from the command printed first)
	@echo "password of admin: kubectl --context k3d-svp -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
	kubectl --context k3d-svp -n argocd port-forward --address 127.0.0.1 service/argocd-server 8081:443

# The k6 Job of the cloud cluster (the output of deploy/k6/cloud/render.sh), checked without a cluster: no kubectl, no
# .env. The steps are at the top of deploy/k8s/cloud/check.sh: kubeconform -strict of KUBECONFORM_IMAGE against the
# Kubernetes schemas of CLOUD_K8S_VERSION (no kind is skipped for want of a schema; a missing one fails), then a digest
# on every image. Needs network access: GitHub. CLOUD_K8S_VERSION is a release whose schemas the commit of
# yannh/kubernetes-json-schema pinned in check.sh holds.
CLOUD_K8S_VERSION := 1.35.9

cloud-check: ## Check the k6 Job of the cloud cluster (deploy/k6/cloud/render.sh) without a cluster: kubeconform -strict (Kubernetes CLOUD_K8S_VERSION), every image pinned by digest (needs network)
	KUBECONFORM_IMAGE='$(KUBECONFORM_IMAGE)' CLOUD_K8S_VERSION='$(CLOUD_K8S_VERSION)' deploy/k8s/cloud/check.sh

# --- An EKS cluster of the project (stage 7), which the infrastructure repository makes and destroys, and its learner
# reaches with the AWS profile of the session (the AI runs none of these). CONTEXT is the cluster's alias in the
# kubeconfig, svp-stg or svp-prd (output kubeconfig_command of the infrastructure repository: aws eks update-kubeconfig
# --alias), never the current context; the scripts get it as SVP_KUBE_CONTEXT, and refuse every other name before any
# command (deploy/k8s/lib.sh, deploy/compose/lib.sh). These targets never run k8s-exclusive: a cluster in the cloud
# takes no memory of this machine. DOMAIN is the domain of the cluster's web client, its API api.<domain>, behind
# certificates of a public CA (no .k8s/ca.crt). LOCAL LAB ONLY: eks-smoke, eks-seed and eks-rl-reset delete the
# register rate limit keys in the cluster's Valkey db 10, as k8s-smoke does on k3d; a stg or prd of this lab only.
CONTEXT ?=
CLUSTER_VALUES ?=
DOMAIN ?=
EKS_CONTEXT_CHECK = case '$(CONTEXT)' in svp-stg | svp-prd) ;; *) echo "make $@: CONTEXT must be svp-stg or svp-prd, the alias of an EKS cluster of the project in the kubeconfig (got '$(CONTEXT)')" >&2; exit 1 ;; esac
EKS_DOMAIN_CHECK = printf '%s' '$(DOMAIN)' | grep -Eqx '([a-z0-9]([a-z0-9-]*[a-z0-9])?[.])+[a-z]{2,}' || { echo "make $@: DOMAIN must be the domain of the cluster's web client, its API at api.<domain> (got '$(DOMAIN)')" >&2; exit 1; }

# deploy/k8s/gitops.sh on the EKS cluster: its steps but the registry and the cluster (made already) and following a
# branch (it stays at the commit checked). CLUSTER_VALUES is the file of the root's value cluster, the JSON of
# `terraform output -json cluster_values` of the infrastructure repository, checked against the keys of
# deploy/ci/cluster-values.example.yaml before any kubectl call. SVP_RDS_MASTER_PASSWORD comes from the environment
# (the session's script reads it from AWS), never from .env.
eks-gitops-up: env-required ## On the EKS cluster CONTEXT=svp-stg|svp-prd, with CLUSTER_VALUES=<file of the root's value cluster> [GITOPS_REV=main, a branch of the clone of svp-gitops or a commit]: check the seven release digests of envs/stg/images/ as k8s-gitops-up does, make the namespaces with the values Argo CD gives svp-cluster on platform eks, write the source Secrets (pg-superuser from SVP_RDS_MASTER_PASSWORD of the environment), install Argo CD and root svp-root (platform eks, cluster from the file) at that commit, wait until every Application is Synced and Healthy; no registry, no k3d cluster, no branch followed
	@$(EKS_CONTEXT_CHECK)
	@test -n '$(CLUSTER_VALUES)' || { echo "make eks-gitops-up: set CLUSTER_VALUES=<file> (terraform output -json cluster_values of the infrastructure repository)" >&2; exit 1; }
	SVP_KUBE_CONTEXT='$(CONTEXT)' CLUSTER_VALUES='$(CLUSTER_VALUES)' GITOPS_REV='$(GITOPS_REV)' deploy/k8s/gitops.sh

eks-secrets: env-required ## Write the source Secrets of namespace svp-secrets of the EKS cluster CONTEXT=svp-stg|svp-prd from .env, pg-superuser from SVP_RDS_MASTER_PASSWORD of the environment (required), none for an object store in the cluster (SVP_OBJECT_STORE=external by default), then have every ExternalSecret built again from them (no value printed)
	@$(EKS_CONTEXT_CHECK)
	SVP_KUBE_CONTEXT='$(CONTEXT)' deploy/k8s/secrets.sh

eks-glitchtip-init: ## As k8s-glitchtip-init on the EKS cluster CONTEXT=svp-stg|svp-prd: GlitchTip's DSN and API tokens into source Secret svp-secrets/glitchtip-runtime, its ExternalSecrets built again, each service restarted that started without the current DSN; idempotent, run by eks-gitops-up
	@$(EKS_CONTEXT_CHECK)
	SVP_KUBE_CONTEXT='$(CONTEXT)' deploy/k8s/glitchtip-init.sh

eks-smoke: ## Run the end-to-end smoke test against the EKS cluster CONTEXT=svp-stg|svp-prd at https://api.<DOMAIN> (public certificates, no CA bundle; LOCAL LAB ONLY: deletes the register rate limit keys in that cluster's Valkey db 10)
	@$(EKS_CONTEXT_CHECK)
	@$(EKS_DOMAIN_CHECK)
	env -u CURL_CA_BUNDLE SVP_STACK=eks SVP_KUBE_CONTEXT='$(CONTEXT)' deploy/compose/smoke.sh 'https://api.$(DOMAIN)'

eks-seed: ## Seed the EKS cluster CONTEXT=svp-stg|svp-prd for k6 through https://api.<DOMAIN>: 4 users upload 8 short videos each, all READY, GET /feed/explore holds at least 30 (LOCAL LAB ONLY: deletes the register rate limit keys in that cluster's Valkey db 10)
	@$(EKS_CONTEXT_CHECK)
	@$(EKS_DOMAIN_CHECK)
	env -u CURL_CA_BUNDLE SVP_STACK=eks SVP_KUBE_CONTEXT='$(CONTEXT)' deploy/k8s/eks-seed.sh 'https://api.$(DOMAIN)'

# Before each level of a load test: every pod of the k6 profile cloud registers its users from its own address, which
# a later pod may get again, so the register burst of one address would run out between levels.
eks-rl-reset: ## Delete the register rate limit keys (svp:gw:rl:register:*, SCAN + DEL) in the Valkey db 10 of the EKS cluster CONTEXT=svp-stg|svp-prd, before each level of a load test (LOCAL LAB ONLY)
	@$(EKS_CONTEXT_CHECK)
	SVP_STACK=eks SVP_KUBE_CONTEXT='$(CONTEXT)' bash -c '. deploy/compose/lib.sh'
