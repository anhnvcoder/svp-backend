{{- /*
Security context of every container this chart runs (Pod Security "restricted"): no privilege
escalation, no capability, a read-only root filesystem (whatever a process writes goes to a declared volume).
*/}}
{{- define "svp-data.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}

{{- /*
Pod security context for the user and group id given (the image's own non-root user): runAsNonRoot makes the kubelet
refuse to start the pod as root even if the id is wrong, seccomp RuntimeDefault filters the syscalls.
*/}}
{{- define "svp-data.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ .uid }}
runAsGroup: {{ .gid }}
{{- if .fsGroup }}
fsGroup: {{ .gid }}
{{- end }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- /*
Annotations of the init Jobs: Helm hooks that run after every install and upgrade, once the release's ordinary
resources (NetworkPolicies, ConfigMaps, Services) are ready (--wait). Argo CD reads them as PostSync hooks.
*/}}

{{- /*
A new run replaces the last Job, whose pod stays until then for its log.
*/}}
{{- define "svp-data.initJobAnnotations" -}}
helm.sh/hook: post-install,post-upgrade
helm.sh/hook-delete-policy: before-hook-creation
{{- end }}

{{- /*
"true" when Postgres is outside the cluster (postgres.mode external), "" when CloudNativePG runs it here; fails on any
other mode, or on external without the host or the CIDRs.
*/}}
{{- define "svp-data.postgresExternal" -}}
{{- $pg := .Values.postgres }}
{{- if not (has $pg.mode (list "cluster" "external")) }}
{{- fail (printf "postgres.mode is %q: cluster (CloudNativePG in the cluster) or external (a managed Postgres)" (toString $pg.mode)) }}
{{- end }}
{{- if eq $pg.mode "external" }}
{{- if not $pg.external.host }}
{{- fail "postgres.mode external needs postgres.external.host, the DNS name of the managed Postgres" }}
{{- end }}
{{- if not $pg.external.cidrs }}
{{- fail "postgres.mode external needs postgres.external.cidrs, the CIDRs of the managed Postgres's addresses" }}
{{- end }}
{{- print "true" }}
{{- end }}
{{- end }}

{{- /*
"true" when the object store is outside the cluster (s3.mode external), "" when s3 runs here; fails on any other mode,
and on external while CloudNativePG in the cluster still archives its WAL into s3.
*/}}
{{- define "svp-data.s3External" -}}
{{- if not (has .Values.s3.mode (list "cluster" "external")) }}
{{- fail (printf "s3.mode is %q: cluster (the object store s3 in the cluster) or external (a managed object store)" (toString .Values.s3.mode)) }}
{{- end }}
{{- if eq .Values.s3.mode "external" }}
{{- if not (include "svp-data.postgresExternal" .) }}
{{- fail "s3.mode external needs postgres.mode external: CloudNativePG archives the WAL and base backups of svp-pg into the object store s3 of the cluster" }}
{{- end }}
{{- print "true" }}
{{- end }}
{{- end }}

{{- /*
"true" when Kafka is outside the cluster (kafka.mode external), "" when the broker runs here; fails on any other mode,
on kafka.brokers not of the form host:9096[,host:9096...], and on external without brokers of its own (still the
Service of the in-cluster broker) or without the CIDRs, or with a CIDR of every address.
*/}}
{{- define "svp-data.kafkaExternal" -}}
{{- $k := .Values.kafka }}
{{- if not (has $k.mode (list "cluster" "external")) }}
{{- fail (printf "kafka.mode is %q: cluster (one Kafka broker in the cluster) or external (a managed Kafka)" (toString $k.mode)) }}
{{- end }}
{{- if not (regexMatch "^[A-Za-z0-9.-]+:9096(,[A-Za-z0-9.-]+:9096)*$" (toString $k.brokers)) }}
{{- fail (printf "kafka.brokers is %q: host:9096 for each broker, comma separated, no spaces" (toString $k.brokers)) }}
{{- end }}
{{- if eq $k.mode "external" }}
{{- if eq $k.brokers (include "svp-data.kafkaService" .) }}
{{- fail "kafka.mode external needs kafka.brokers, the bootstrap brokers of the managed Kafka: it still names the Service of the in-cluster broker" }}
{{- end }}
{{- include "svp-data.externalCidrs" (dict "name" "kafka" "cidrs" $k.external.cidrs "port" 9096) }}
{{- print "true" }}
{{- end }}
{{- end }}

{{- /*
"true" when Valkey is outside the cluster (valkey.mode external), "" when it runs here; fails on any other mode, on an
empty valkey.host, and on external that still names the in-cluster Service, has no CIDRs or a CIDR of every address.
*/}}
{{- define "svp-data.valkeyExternal" -}}
{{- $v := .Values.valkey }}
{{- if not (has $v.mode (list "cluster" "external")) }}
{{- fail (printf "valkey.mode is %q: cluster (Valkey in the cluster) or external (a managed Valkey)" (toString $v.mode)) }}
{{- end }}
{{- if not (regexMatch "^[A-Za-z0-9.-]+$" (toString $v.host)) }}
{{- fail (printf "valkey.host is %q: the host name of Valkey, without a port" (toString $v.host)) }}
{{- end }}
{{- if eq $v.mode "external" }}
{{- if eq $v.host (include "svp-data.valkeyService" .) }}
{{- fail "valkey.mode external needs valkey.host, the primary endpoint of the managed Valkey: it still names the Service of the in-cluster Valkey" }}
{{- end }}
{{- include "svp-data.externalCidrs" (dict "name" "valkey" "cidrs" $v.external.cidrs "port" 6379) }}
{{- print "true" }}
{{- end }}
{{- end }}

{{- /*
Fails unless the CIDRs of a managed server (dict: name, cidrs, port) are set and none is every address: the clients
here reach that server's own subnets, never the internet.
*/}}
{{- define "svp-data.externalCidrs" -}}
{{- if not .cidrs }}
{{- fail (printf "%s.mode external needs %s.external.cidrs, the CIDRs of the managed %s's addresses" .name .name .name) }}
{{- end }}
{{- range .cidrs }}
{{- if has . (list "0.0.0.0/0" "::/0") }}
{{- fail (printf "%s.external.cidrs holds %s, every address: list the subnets of the managed %s" $.name . $.name) }}
{{- end }}
{{- end }}
{{- end }}

{{- /*
The names the in-cluster broker and Valkey are reached at: their Services, in the long form the server certificate of
the local CA holds. The broker advertises exactly this address to its clients.
*/}}
{{- define "svp-data.kafkaService" -}}
{{- printf "kafka.%s.svc.cluster.local:9096" .Release.Namespace }}
{{- end }}
{{- define "svp-data.valkeyService" -}}
{{- printf "valkey.%s.svc.cluster.local" .Release.Namespace }}
{{- end }}

{{- /*
The egress peers of a Kafka or Valkey client here (dict: name kafka|valkey, external, cidrs): the server's pods in this
namespace, or the CIDRs of the managed server.
*/}}
{{- define "svp-data.serverPeers" -}}
{{- if .external }}
{{- range .cidrs }}
- ipBlock:
    cidr: {{ . }}
{{- end }}
{{- else }}
- podSelector:
    matchLabels:
      app.kubernetes.io/name: {{ .name }}
{{- end }}
{{- end }}
