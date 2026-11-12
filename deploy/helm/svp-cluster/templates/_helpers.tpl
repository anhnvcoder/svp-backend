{{- /* The HTTPS listeners of Gateway svp as a YAML list, read by templates/gateway.yaml and certificates.yaml: value
listeners, or by default one listener for wildcardHost and one for apexHost. A wildcard does not cover the name it is
under, so the apex gets a listener and a certificate of its own. */}}
{{- define "svp-cluster.listeners" -}}
{{- if .Values.listeners }}
{{- $names := list }}
{{- range $l := .Values.listeners }}
{{- $names = append $names $l.name }}
{{- range $key := list "name" "certificate" "secretName" "dnsNames" }}
{{- if not (index $l $key) }}
{{- fail (printf "listeners: every entry needs %s (%s)" $key (toJson $l)) }}
{{- end }}
{{- end }}
{{- end }}
{{- if not (has "https" $names) }}
{{- fail "listeners: one entry must be named https, the listener routes of other charts attach to by sectionName" }}
{{- end }}
{{- toYaml .Values.listeners }}
{{- else }}
- name: https
  hostname: {{ .Values.wildcardHost | quote }}
  certificate: svp-wildcard
  secretName: svp-wildcard-tls
  dnsNames:
    - {{ .Values.wildcardHost | quote }}
- name: https-apex
  hostname: {{ .Values.apexHost | quote }}
  certificate: svp-apex
  secretName: svp-apex-tls
  dnsNames:
    - {{ .Values.apexHost | quote }}
{{- end }}
{{- end }}
