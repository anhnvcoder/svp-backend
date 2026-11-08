{{- /*
Labels of the service's own pods: name is the service name, the label svp-data's policies open their servers to;
component (server or migrate) keeps the Service and the server's policies from selecting a Job pod.
*/}}
{{- define "svp-service.selectorLabels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/component: server
{{- end }}

{{- define "svp-service.labels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/part-of: svp
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- /*
The image. With a digest (the GitOps path) the pod runs <repository>:<tag>@<digest>; the tag only tells people which
commit it is, since a tag can be pushed again. Without one (the dev path) the tag must be set.
*/}}
{{- define "svp-service.image" -}}
{{- $repository := required (printf "image.repository is empty for release %s" .Release.Name) .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{ $repository }}{{ with .Values.image.tag }}:{{ . }}{{ end }}@{{ .Values.image.digest }}
{{- else -}}
{{- $msg := printf "image.tag and image.digest are empty for release %s:" .Release.Name -}}
{{- $msg = printf "%s on the dev path make k8s-up passes the dev tag with --set image.tag=...;" $msg -}}
{{- $msg = printf "%s on the GitOps path the promote pull request writes image.tag and image.digest into" $msg -}}
{{- $msg = printf "%s envs/<env>/images/%s.yaml of svp-gitops" $msg .Release.Name -}}
{{ $repository }}:{{ required $msg .Values.image.tag }}
{{- end }}
{{- end }}

{{- /*
Security context (Pod Security "restricted" of namespace svp): the images' non-root user 65532, which runAsNonRoot makes
the kubelet check, seccomp RuntimeDefault, no privilege escalation, no capability, a read-only root filesystem.
*/}}
{{- define "svp-service.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
{{- if .Values.localCA }}
# The group a volume of the local CA's Secret (mode 0440) is readable by.
fsGroup: 65532
{{- end }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "svp-service.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}

{{- /*
A peer of .Values.peers as one entry of a NetworkPolicy's `from` or `to`: its namespace and its pods' labels.
*/}}
{{- define "svp-service.peerSelector" -}}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ .namespace }}
  podSelector:
    matchLabels:
      {{- toYaml .labels | nindent 6 }}
{{- end }}

{{- /*
The egress rules to a peer of .Values.externalPeers (dict: name, entries): one rule per entry, its ipBlock and ports.
An entry for every address is refused: a service reaches its managed peer's own ranges, never the internet.
*/}}
{{- define "svp-service.externalEgress" -}}
{{- range .entries }}
{{- if not (and .cidr .ports) }}{{ fail (printf "externalPeers.%s: every entry needs a cidr and ports" $.name) }}{{ end }}
{{- range $key, $_ := . }}{{ if not (has $key (list "cidr" "ports")) }}{{ fail (printf "externalPeers.%s: unknown key %q (an entry has cidr and ports only)" $.name $key) }}{{ end }}{{ end }}
{{- if has .cidr (list "0.0.0.0/0" "::/0") }}{{ fail (printf "externalPeers.%s: %s is every address; list the service's own ranges" $.name .cidr) }}{{ end }}
- to:
    - ipBlock:
        cidr: {{ .cidr }}
  ports:
    {{- range .ports }}
    - protocol: TCP
      port: {{ . }}
    {{- end }}
{{- end }}
{{- end }}

{{- /*
Name of the release's HTTPRoute: httpRoute.name, or the release's name. The gateway keeps the name api it always had,
which the drills and Argo CD's ignoreDifferences read.
*/}}
{{- define "svp-service.routeName" -}}
{{ .Values.httpRoute.name | default .Release.Name }}
{{- end }}
