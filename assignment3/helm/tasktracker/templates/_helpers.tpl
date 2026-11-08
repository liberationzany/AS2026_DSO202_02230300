{{/*
_helpers.tpl - named templates shared by every manifest. Nothing here
renders on its own.
*/}}

{{/*
tasktracker.fullname - the prefix for every object name.
The release name alone if it already contains the chart name ("tasktracker",
"tasktracker-dev"), otherwise "<release>-tasktracker". Cut to 52 characters,
leaving room for suffixes such as "-frontend", within the 63-character DNS
label limit. Prefixing by release lets two releases share a namespace.
*/}}
{{- define "tasktracker.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 52 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 52 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
tasktracker.labels - the recommended label set, on every object.
*/}}
{{- define "tasktracker.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: tasktracker
{{- end -}}

{{/*
tasktracker.selectorLabels - the minimal, NEVER-changing labels used in
selectors. Takes a dict: (dict "ctx" $ "component" "backend").
Selectors are immutable after creation, so no version or chart label here.
*/}}
{{- define "tasktracker.selectorLabels" -}}
app.kubernetes.io/name: {{ .ctx.Chart.Name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
tasktracker.origin - the public HTTPS origin the browser uses, derived
from the Ingress host and port (":443" is omitted, as browsers do).
Used for BACKEND_URL and CORS_ORIGIN, so they always match the Ingress.
*/}}
{{- define "tasktracker.origin" -}}
{{- $scheme := ternary "https" "http" .Values.ingress.tls.enabled -}}
{{- $default := ternary 443 80 .Values.ingress.tls.enabled -}}
{{- if eq (int .Values.ingress.publicPort) $default -}}
{{- printf "%s://%s" $scheme .Values.ingress.host -}}
{{- else -}}
{{- printf "%s://%s:%d" $scheme .Values.ingress.host (int .Values.ingress.publicPort) -}}
{{- end -}}
{{- end -}}

{{/* Name of the TLS Secret: given, or "<fullname>-tls". */}}
{{- define "tasktracker.tlsSecretName" -}}
{{- default (printf "%s-tls" (include "tasktracker.fullname" .)) .Values.ingress.tls.secretName -}}
{{- end -}}

{{/* image reference for a tier: (include "tasktracker.image" .Values.images.backend) */}}
{{- define "tasktracker.image" -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end -}}
