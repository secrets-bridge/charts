{{/*
Common naming + labels. Mirrors the bitnami / argo-cd pattern: one
`fullname` per component derived from the release name + component
key, plus shared selector labels.
*/}}

{{/* Chart name + version label value (≤63 chars). */}}
{{- define "secrets-bridge.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Release-wide name, overridable by `nameOverride`. */}}
{{- define "secrets-bridge.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Release-wide fullname (release + chart name), overridable by `fullnameOverride`. */}}
{{- define "secrets-bridge.fullname" -}}
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

{{/*
Per-component fullname: `<release>-<component>` (e.g.
`secrets-bridge-api`, `secrets-bridge-ui`). Argument is the component
short name as a string.

Usage: {{ include "secrets-bridge.componentName" (dict "ctx" . "component" "api") }}
*/}}
{{- define "secrets-bridge.componentName" -}}
{{- $ctx := .ctx -}}
{{- $component := .component -}}
{{- printf "%s-%s" (include "secrets-bridge.fullname" $ctx) $component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels — applied to EVERY resource the chart renders.
Component-specific labels (app.kubernetes.io/component) get layered
on top by the component templates.
*/}}
{{- define "secrets-bridge.labels" -}}
helm.sh/chart: {{ include "secrets-bridge.chart" . }}
app.kubernetes.io/name: {{ include "secrets-bridge.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: secrets-bridge
{{- with .Values.global.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Per-component selector labels — only the bits used for Service / Deployment matching. */}}
{{- define "secrets-bridge.componentSelectorLabels" -}}
{{- $ctx := .ctx -}}
{{- $component := .component -}}
app.kubernetes.io/name: {{ include "secrets-bridge.name" $ctx }}
app.kubernetes.io/instance: {{ $ctx.Release.Name }}
app.kubernetes.io/component: {{ $component }}
{{- end -}}

{{/* Per-component full label set — common + selector. */}}
{{- define "secrets-bridge.componentLabels" -}}
{{ include "secrets-bridge.labels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Common annotations — applied wherever `commonAnnotations` is used.
*/}}
{{- define "secrets-bridge.annotations" -}}
{{- with .Values.global.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Image reference — fully qualified.

Usage: {{ include "secrets-bridge.image" (dict "ctx" . "image" .Values.api.image) }}
*/}}
{{- define "secrets-bridge.image" -}}
{{- $ctx := .ctx -}}
{{- $image := .image -}}
{{- $registry := default $ctx.Values.global.imageRegistry "" -}}
{{- $tag := default $ctx.Chart.AppVersion $image.tag -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry $image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" $image.repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
ServiceAccount name for a component.

Usage: {{ include "secrets-bridge.componentServiceAccountName" (dict "ctx" . "component" "api" "spec" .Values.api.serviceAccount) }}
*/}}
{{- define "secrets-bridge.componentServiceAccountName" -}}
{{- $ctx := .ctx -}}
{{- $component := .component -}}
{{- $spec := .spec -}}
{{- if $spec.create -}}
{{- default (include "secrets-bridge.componentName" (dict "ctx" $ctx "component" $component)) $spec.name -}}
{{- else -}}
{{- default "default" $spec.name -}}
{{- end -}}
{{- end -}}
