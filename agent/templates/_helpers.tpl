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
Read-only directory the agent reads agent_id, agent_secret and private_key
from (SB_AGENT_CREDENTIALS_DIR). Fixed: the agent's default.
*/}}
{{- define "secrets-bridge-agent.credentialsDir" -}}
/etc/secrets-bridge/agent
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

{{/*
Pinned-image allow-lists (CHT-N-01). Same patterns as
`secrets-bridge.pinnedTagRegex` / `.digestRegex` in the control-plane
chart; keep them in sync. Tags: full semver (`1.2.3`, `v1.2.3`,
`1.2.3-rc.1`) or the `sha-<commit>` tag the agent's docker-publish
workflow pushes. Digests: `sha256:` plus 64 lowercase hex characters.
*/}}
{{- define "secrets-bridge-agent.pinnedTagRegex" -}}
^(v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?|sha-[0-9a-f]{7,64})$
{{- end -}}

{{- define "secrets-bridge-agent.digestRegex" -}}
^sha256:[0-9a-f]{64}$
{{- end -}}

{{/*
Chart dev versions (`X.Y.Z-dev.<charts commit>`, what chart-publish.yml
names a chart built from main). They match pinnedTagRegex as a semver
prerelease, but no image is tagged with one, and charts published
before charts#31 used one as appVersion. Same pattern as
`secrets-bridge.chartDevVersionRegex`; keep them in sync.
*/}}
{{- define "secrets-bridge-agent.chartDevVersionRegex" -}}
^v?[0-9]+\.[0-9]+\.[0-9]+-dev\.
{{- end -}}

{{/*
True when the agent authenticates to Vault with the Kubernetes auth
method: the resolver then reads the pod's ServiceAccount token from the
hard-pinned path /var/run/secrets/kubernetes.io/serviceaccount/token.
Emits "true" or "".
*/}}
{{- define "secrets-bridge-agent.vaultKubernetesAuth" -}}
{{- if and .Values.providers.vault.enabled .Values.providers.vault.kubernetesRole -}}
true
{{- end -}}
{{- end -}}

{{/*
Effective automountServiceAccountToken (CHT-N-06), used for both the
ServiceAccount and the pod spec. An explicit true/false in
serviceAccount.automountServiceAccountToken wins; unset (null, the
default) means "only when Vault Kubernetes auth needs the token".
AWS IRSA / EKS Pod Identity don't need it: their webhooks project
their own token. Emits "true" or "false".
*/}}
{{- define "secrets-bridge-agent.automountServiceAccountToken" -}}
{{- $explicit := toString .Values.serviceAccount.automountServiceAccountToken -}}
{{- if has $explicit (list "true" "false") -}}
{{- $explicit -}}
{{- else if include "secrets-bridge-agent.vaultKubernetesAuth" . -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}
