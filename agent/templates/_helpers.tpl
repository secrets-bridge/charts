{{/* Chart name + version label. */}}
{{- define "secrets-bridge-agent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Release name override target. */}}
{{- define "secrets-bridge-agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "secrets-bridge-agent.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "secrets-bridge-agent.labels" -}}
helm.sh/chart: {{ include "secrets-bridge-agent.chart" . }}
app.kubernetes.io/name: {{ include "secrets-bridge-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: secrets-bridge
app.kubernetes.io/component: agent
{{- with .Values.global.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "secrets-bridge-agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "secrets-bridge-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: agent
{{- end -}}

{{- define "secrets-bridge-agent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "secrets-bridge-agent.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
identity.mode == "file" → the agent reads/writes SB_IDENTITY_FILE on a
writable persistent volume (enrollment). Emits "true" or "". Validation
keeps this 1:1 with enrollment.enabled.
*/}}
{{- define "secrets-bridge-agent.fileMode" -}}
{{- if eq .Values.identity.mode "file" -}}
true
{{- end -}}
{{- end -}}

{{/* PVC name for FILE-mode identity persistence (BYO existingClaim wins). */}}
{{- define "secrets-bridge-agent.identityClaimName" -}}
{{- if .Values.identity.persistence.existingClaim -}}
{{- .Values.identity.persistence.existingClaim -}}
{{- else -}}
{{- printf "%s-identity" (include "secrets-bridge-agent.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Absolute path of the persisted identity file (SB_IDENTITY_FILE). */}}
{{- define "secrets-bridge-agent.identityFilePath" -}}
{{- printf "%s/%s" (trimSuffix "/" .Values.identity.mountPath) .Values.identity.fileName -}}
{{- end -}}

{{/*
Image reference, fully qualified. Prefers an immutable digest pin
(`image.digest`, a `sha256:...` value) over the mutable `image.tag`;
when `digest` is set, `tag` is ignored entirely. Mirrors
`secrets-bridge.image` in the control-plane chart.
*/}}
{{- define "secrets-bridge-agent.image" -}}
{{- $registry := default .Values.global.imageRegistry "" -}}
{{- $repo := ternary (printf "%s/%s" $registry .Values.image.repository) .Values.image.repository (ne $registry "") -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repo .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}
{{- end -}}
