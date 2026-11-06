{{- define "leadpipe.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "leadpipe.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 50 | trimSuffix "-" }}
{{- else if contains (include "leadpipe.name" .) .Release.Name }}
{{- .Release.Name | trunc 50 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "leadpipe.name" .) | trunc 50 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "leadpipe.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
app.kubernetes.io/name: {{ include "leadpipe.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | trunc 63 | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels never include the version, because a Deployment's selector is immutable. */}}
{{- define "leadpipe.selectorLabels" -}}
app.kubernetes.io/name: {{ include "leadpipe.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/* Builds an image reference, and fails the render if the tag is not a traceable release. */}}
{{- define "leadpipe.image" -}}
{{- $tag := required "image.tag is required: pass the git commit SHA" .root.Values.image.tag -}}
{{- if eq $tag "latest" -}}
{{- fail "image.tag must not be \"latest\": every release has to trace back to a commit" -}}
{{- end -}}
{{- if .root.Values.image.registry -}}
{{- printf "%s/%s:%s" .root.Values.image.registry .repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .repository $tag -}}
{{- end -}}
{{- end }}

{{- define "leadpipe.redisHost" -}}
{{- .Values.redis.host | default (printf "%s-redis" (include "leadpipe.fullname" .)) -}}
{{- end }}

{{/* Database credentials. Each pod receives only the secret keys it uses. */}}
{{- define "leadpipe.dbCredentialsEnv" -}}
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.name }}
      key: DB_USER
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.name }}
      key: DB_PASSWORD
{{- end }}
