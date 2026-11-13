{{- /* The annotations of every object of ACK's controller. Argo CD skips its dry run while the CRDs, which the
controller's own release installs, are not there yet; ACK adopts the workspace's object a session left behind instead
of failing to create it again. */}}
{{- define "svp-observability.ackAnnotations" -}}
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
services.k8s.aws/adoption-policy: adopt-or-create
{{- end }}
{{- /* The same dry-run exception for the objects of Grafana Operator, whose CRDs its release installs. */}}
{{- define "svp-observability.grafanaOperatorAnnotations" -}}
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end }}
