# Local Kubernetes targets (k3d cluster svp), included by the root Makefile, and the eks-* targets for an EKS cluster
# of the project (at the end). docker and k3d run without DOCKER_DEFAULT_PLATFORM and kubectl/helm always name their
# context, --context k3d-svp on every target but eks-*; the shell helpers behind these targets are in deploy/k8s/lib.sh.
# Design notes: docs/reference/k8s.md.

K8S_LIB := . deploy/k8s/lib.sh

.PHONY: k8s-exclusive k8s-up k8s-down k8s-status k8s-ca k8s-secrets k8s-images k8s-smoke \
	k8s-glitchtip-init k8s-ui-grafana k8s-ui-prometheus k8s-ui-alertmanager k8s-ui-glitchtip k8s-gitops-up \
	k8s-ui-argocd k8s-traffic-start k8s-traffic-stop drill-k8s-threats \
	drill-k8s-supplychain drill-k8s-gitops drill-k8s-reloader k8s-web-sourcemaps k8s-web-e2e cloud-check \
	gitops-clone web-clone eks-secrets eks-glitchtip-init eks-smoke eks-seed \
	eks-rl-reset

# Compose and k3d never run together on the 16 GB machine (they do not fit in its RAM): the cluster is not created or
# started beside a running compose stack. `make up` refuses the other way round (deploy/compose/compose.mk).
k8s-exclusive:
	@running=$$(env -u DOCKER_DEFAULT_PLATFORM docker compose -p svp ps -q); \
	  if [ -n "$$running" ]; then echo "make k8s-up: the compose stack svp is running; run 'make down' first" >&2; exit 1; fi

# env-required, local-ca: the Secrets come from .env and .local/ca/ (deploy/k8s/secrets.sh, run by install.sh once the
# namespaces exist); like the clone of svp-gitops (gitops_dir), a missing one stops the target before anything is made.
# helmfile installs the releases (deploy/k8s/helmfile.yaml.gotmpl, HELMFILE_VERSION of the Makefile: make tools).
# The six backend services are always built here: IMAGES is make up's alone.
k8s-up: k8s-exclusive env-required local-ca ## Create (or start) the registry 127.0.0.1:5111 and cluster svp (API 127.0.0.1:6550, HTTPS 127.0.0.1:8443), build and push the six backend images (WEB_FROM=clone: the web client's too, from the clone of svp-frontend, ../frontend or SVP_WEB_DIR; otherwise the web client runs its staging release, or WEB_IMAGE=<ghcr.io/...@sha256:...> with WEB_FROM=image), install argocd/apps/components.json of the clone of svp-gitops (../gitops beside the checkout, or SVP_GITOPS_DIR) with its base/ values through helmfile, with drill traffic while a canary of the gateway or the web client runs; idempotent (LOCAL LAB ONLY: a canary's drill traffic resets register rate limit keys in the cluster's Valkey db 10)
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

# The GitOps path: a new cluster svp that Argo CD builds from GitHub, running the release images of GHCR, as staging:
# base/ of svp-gitops plus the overlays and release images of its envs/stg, with the charts of this repository at the
# commit envs/stg/charts.yaml pins (production is only rendered, by the checks). GITOPS_REV is the revision Argo CD
# follows: a branch of the clone's origin or a full SHA. Argo CD reads both public repos over HTTPS: no deploy key.
GITOPS_REV ?= main

k8s-gitops-up: k8s-exclusive env-required local-ca ## Create a new cluster svp that runs as staging (base/ plus envs/stg of svp-gitops), built by Argo CD from GitHub over anonymous HTTPS (no deploy key) [GITOPS_REV=main, a branch of the clone of svp-gitops or a commit]; first checks that the seven release digests of envs/stg/images/ at that revision are on GHCR (anonymous pull), signed, with a clean vuln attestation at most 48 h old; applies the Secrets of .env, installs Argo CD with the plugin of Argo Rollouts for the nodes' architecture, waits until every Application is Synced and Healthy
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

k8s-secrets: env-required ## Create or update the cluster's Secrets from .env, a whole change of credentials (no value printed): a changed password of Kafka's svp-admin set in broker kafka-0 first through Deployment svp-ops (both must run), the Secrets of svp-data (with the local CA of .local/ca/ and Valkey's ACL file), a wait until the object store and Valkey run with them (Reloader restarts them), the init Jobs of svp-data that set the new passwords (dev path: helmfile, release svp-data alone; GitOps cluster: a sync of Application svp-data), then the clients' Secrets, whose workloads Reloader restarts. On a cluster with namespace svp-secrets (GitOps staging with External Secrets) it writes only the source Secrets there and has the ExternalSecrets built again from them, those of svp-data first. Refuses, before writing anything, a cluster that runs the project's workloads without Reloader or with a workload that does not name its Secrets for it yet, or (dev path) that Reloader may not restart (make k8s-up installs them)
	SVP_KUBE_CONTEXT=k3d-svp deploy/k8s/secrets.sh

# Needs no .env: both values are GlitchTip's own, read inside its pod (deploy/k8s/glitchtip-init.sh).
k8s-glitchtip-init: ## Put GlitchTip's DSN into Secret svp/sentry and its read-only API token into Secret svp-obs/glitchtip-api (never into .env, nothing printed); Reloader restarts each service whose DSN changed; idempotent, run by make k8s-up
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

K8S_DRILL_ENV := SVP_STACK=k3d CURL_CA_BUNDLE=$(CURDIR)/.k8s/ca.crt

# The canaries of the gateway and the web client. The drill traffic runs in the background until stopped, for hours
# if need be (through the push of a release on the GitOps cluster); `make k8s-up` starts and stops its own while a
# canary of either is in progress.
k8s-traffic-start: ## Start drill traffic in the background: 4 users, ~10 requests/s to GET /feed/explore and /feed/following through https://api.svp.localhost:8443, and ~4 requests/s to the web client at https://svp.localhost:8443 (GET /login, one /_next/static asset), each request logged in .k8s/drills/traffic-<time>.log (LOCAL LAB ONLY: resets register rate limit keys in the cluster's Valkey db 10)
	@test -s .k8s/ca.crt || { echo "make k8s-traffic-start: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)" >&2; exit 1; }
	@$(K8S_DRILL_ENV) deploy/k8s/drills/traffic.sh start

k8s-traffic-stop: ## Stop the drill traffic started by k8s-traffic-start (the pid it recorded, nothing else) and print its requests by status
	@deploy/k8s/drills/traffic.sh stop

# The drills on cluster svp are Chainsaw tests under deploy/k8s/drills/<drill>/, run by deploy/k8s/drills/run.sh: one
# call of chainsaw per drill (never two drills together), context k3d-svp checked before it, the tests one at a time;
# what each test checks is written in the test. threats needs .k8s/ca.crt (run.sh checks it) and the gateway.
drill-k8s-threats: ## Check the threat model rows on cluster svp, each with a control case: a probe pod in namespace svp-probe (created, then deleted) and media-worker reach only what the NetworkPolicies allow, Kafka ACLs per user, pod security and PSA, no trust in pg_hba, login rate limit ignores forged X-Forwarded-For, no pprof/metrics, no exposed UI, Grafana 401, no ServiceAccount reads secrets or pods; web client: no token or JWT in pages, RSC or /api JSON and /api/ outside the BFF list 400/404 (WEB-7), cross-site or same-site POSTs 403 CSRF_REJECTED (WEB-2), the object store's CORS per bucket for https://svp.localhost:8443 only, POST to uploads and GET at media only (WEB-10), web pods reach only gateway, Valkey, Collector, GlitchTip (WEB-13), login rate limit through the /login form counts the address Envoy wrote (WEB-8); object store user svp-pg-backup reads only bucket pg-backups and no service's user reads it (BAK-1); on a cluster with External Secrets Operator: each store's ServiceAccount gets only its namespace's source Secrets by name (SEC-6), the controller writes Secrets only where its ExternalSecrets are and makes tokens only for the stores (SEC-5, its read of every Secret printed as an exception), no ServiceAccount of svp creates ExternalSecrets or SecretStores (SEC-7); one Chainsaw test per row (deploy/k8s/drills/threats/), log and JUnit report in .k8s/drills/threats-<UTC>.log and .xml, both searched for the Secret values read; needs make k8s-smoke run before (LOCAL LAB ONLY: resets register rate limit keys in the cluster's Valkey db 10)
	deploy/k8s/drills/run.sh threats

# The image policy of namespace svp. It talks to the cluster's API, to GHCR (anonymous) for the newest drill images,
# and for the CRITICAL case and the case without provenance to GHCR and Sigstore through cosign (anonymous, COSIGN_IMAGE when cosign is not installed), so it needs
# neither .k8s/ca.crt nor the gateway, and deletes no rate limit key. The variables become the Chainsaw values unsigned,
# vulnerable, noProvenance and enforceTmp (deploy/k8s/drills/run.sh).
drill-k8s-supplychain: ## Check Kyverno's image policy of namespace svp: a signed, clean release admitted; unsigned (SUPPLYCHAIN_UNSIGNED=<GHCR digest>, default the newest drill-unsigned on GHCR), CRITICAL (SUPPLYCHAIN_VULNERABLE=<GHCR digest>, attestation within the maximum age), outside GHCR, without digest, attestation too old, ephemeral container and image UPDATE refused, a release without build provenance (SUPPLYCHAIN_NO_PROVENANCE=<GHCR digest>, its vuln attestation within the maximum age) refused when the running policy checks provenance, each with its rule's message; Kyverno down refuses svp only; one Chainsaw test per case (deploy/k8s/drills/supplychain/), log and JUnit report in .k8s/drills/supplychain-<UTC>.log and .xml (dev path, whose policy is Audit: SUPPLYCHAIN_ENFORCE_TMP=1 switches it to Enforce for the drill and back)
	SUPPLYCHAIN_UNSIGNED='$(SUPPLYCHAIN_UNSIGNED)' SUPPLYCHAIN_VULNERABLE='$(SUPPLYCHAIN_VULNERABLE)' \
	  SUPPLYCHAIN_NO_PROVENANCE='$(SUPPLYCHAIN_NO_PROVENANCE)' \
	  SUPPLYCHAIN_ENFORCE_TMP='$(SUPPLYCHAIN_ENFORCE_TMP)' \
	  deploy/k8s/drills/run.sh supplychain

drill-k8s-gitops: ## Check the GitOps cluster svp (make k8s-gitops-up): one Chainsaw test per check (deploy/k8s/drills/gitops/), log and JUnit report in .k8s/drills/gitops-<UTC>.log and .xml
	deploy/k8s/drills/run.sh gitops

drill-k8s-reloader: ## Check a change of credentials on cluster svp (dev path or GitOps): make k8s-secrets with new values, then each workload that reads a changed Secret restarted by Reloader, and a run with the same values that changes no pod; Chainsaw tests under deploy/k8s/drills/reloader/, log and JUnit report in .k8s/drills/reloader-<UTC>.log and .xml; needs make k8s-smoke run before
	deploy/k8s/drills/run.sh reloader

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
# target runs the target of svp-frontend its help names in the clone web_dir names (IN_WEB), against this checkout's
# cluster, .k8s/ca.crt and scripts (deploy/observability/glitchtip/sourcemaps.sh). The source maps are uploaded through
# a port-forward of its own on 127.0.0.1:8000, closed at the end. SVP_E2E_EVIDENCE as for web-e2e.
k8s-web-sourcemaps: ## Upload the source maps of the web client's browser bundle, from the build cluster svp runs (dev path, make k8s-up WEB_FROM=clone), to its GlitchTip with the token of Secret svp-obs/glitchtip-sourcemaps; checks first that the web serves that build (port 127.0.0.1:8000 must be free) (make k8s-sourcemaps of svp-frontend)
	@$(IN_WEB) k8s-sourcemaps

k8s-web-e2e: ## Playwright end-to-end tests of the web client on Chromium and WebKit against cluster svp at https://svp.localhost:8443 (CA .k8s/ca.crt); SVP_E2E_GLITCHTIP=1 adds the browser error to GlitchTip check (needs make k8s-web-sourcemaps first, port 127.0.0.1:8000 free); SVP_E2E_EVIDENCE=<absolute folder> as for web-e2e (make k8s-e2e of svp-frontend; LOCAL LAB ONLY: deletes the register rate limit keys in the cluster's Valkey db 10)
	@$(IN_WEB) k8s-e2e

k8s-ui-argocd: ## Open Argo CD of the GitOps cluster on https://127.0.0.1:8081 (port-forward, loopback only; its own self-signed certificate; log in as admin, password from the command printed first)
	@echo "password of admin: kubectl --context k3d-svp -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
	kubectl --context k3d-svp -n argocd port-forward --address 127.0.0.1 service/argocd-server 8081:443

# The k6 Job of the cloud cluster (the output of deploy/k6/cloud/render.sh), checked without a cluster: no kubectl, no
# .env (steps at the top of deploy/k8s/cloud/check.sh). Needs network access: GitHub. CLOUD_K8S_VERSION is a release
# whose schemas the commit of yannh/kubernetes-json-schema pinned in check.sh holds.
CLOUD_K8S_VERSION := 1.35.9

cloud-check: ## Check the k6 Job of the cloud cluster (deploy/k6/cloud/render.sh) without a cluster: kubeconform -strict (Kubernetes CLOUD_K8S_VERSION), every image pinned by digest (needs network)
	KUBECONFORM_IMAGE='$(KUBECONFORM_IMAGE)' CLOUD_K8S_VERSION='$(CLOUD_K8S_VERSION)' deploy/k8s/cloud/check.sh

# --- An EKS cluster of the project, reached with the AWS profile of the session (the AI runs none of these). CONTEXT
# is the cluster's alias in the kubeconfig, svp-stg or svp-prd, never the current context; the scripts get it as
# SVP_KUBE_CONTEXT, and refuse every other name before any command (deploy/k8s/lib.sh, deploy/compose/lib.sh). These
# targets never run k8s-exclusive: a cluster in the cloud takes no memory of this machine.

# DOMAIN is the domain of the cluster's web client, its API api.<domain>, behind certificates of a public CA (no
# .k8s/ca.crt). LOCAL LAB ONLY: eks-smoke, eks-seed and eks-rl-reset delete the register rate limit keys in the
# cluster's Valkey db 10, as k8s-smoke does on k3d; a stg or prd of this lab only.
CONTEXT ?=
DOMAIN ?=
EKS_CONTEXT_CHECK = case '$(CONTEXT)' in svp-stg | svp-prd) ;; *) echo "make $@: CONTEXT must be svp-stg or svp-prd, the alias of an EKS cluster of the project in the kubeconfig (got '$(CONTEXT)')" >&2; exit 1 ;; esac
EKS_DOMAIN_CHECK = printf '%s' '$(DOMAIN)' | grep -Eqx '([a-z0-9]([a-z0-9-]*[a-z0-9])?[.])+[a-z]{2,}' || { echo "make $@: DOMAIN must be the domain of the cluster's web client, its API at api.<domain> (got '$(DOMAIN)')" >&2; exit 1; }

# The source of every Secret of an EKS cluster is AWS Secrets Manager, entries svp/<env>/<entry> (deploy/k8s/lib.sh):
# both targets take AWS_PROFILE (the profile of the account of the environment, whose id SVP_AWS_<ENV>_ACCOUNT_ID of
# the session's terminal must match) from the environment, and name it and the region in every aws call.
# SVP_RDS_MASTER_PASSWORD comes from the environment (the session's script reads it from AWS), never from .env.
eks-secrets: env-required ## With AWS_PROFILE=<profile of the environment>, write the entries svp/<env>/* of AWS Secrets Manager of the EKS cluster CONTEXT=svp-stg|svp-prd from .env (keys of chart svp-cluster's files/external-secrets.yaml), pg-superuser from SVP_RDS_MASTER_PASSWORD of the environment (required), glitchtip-runtime empty only while it has no value; kafka-admin, kafka-users and valkey-users only checked to exist (Terraform of the infrastructure repository writes them with Amazon MSK and ElastiCache); on a running environment (Reloader must run there) a whole change of credentials: the ExternalSecrets of svp-data built again, Application svp-data synced (its init Jobs set the new passwords), then every other ExternalSecret built again, whose workloads Reloader restarts (no value printed)
	@$(EKS_CONTEXT_CHECK)
	SVP_KUBE_CONTEXT='$(CONTEXT)' deploy/k8s/aws-secrets.sh

eks-glitchtip-init: ## With AWS_PROFILE=<profile of the environment>, as k8s-glitchtip-init on the EKS cluster CONTEXT=svp-stg|svp-prd once Application svp-observability is Healthy: GlitchTip's DSN and API tokens into entry svp/<env>/glitchtip-runtime of AWS Secrets Manager, its three ExternalSecrets built again; Reloader restarts each service whose DSN changed; idempotent
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
