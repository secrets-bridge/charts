{{/* Chart name + version label. */}}
{{- define "secrets-bridge-gateway.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "secrets-bridge-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "secrets-bridge-gateway.fullname" -}}
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

{{/* ConfigMap name: fullname cut short enough for the suffix. */}}
{{- define "secrets-bridge-gateway.connectorsConfigMapName" -}}
{{- printf "%s-connectors" (include "secrets-bridge-gateway.fullname" . | trunc 52 | trimSuffix "-") -}}
{{- end -}}

{{- define "secrets-bridge-gateway.labels" -}}
helm.sh/chart: {{ include "secrets-bridge-gateway.chart" . }}
app.kubernetes.io/name: {{ include "secrets-bridge-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: secrets-bridge
app.kubernetes.io/component: gateway
{{- with .Values.global.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "secrets-bridge-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "secrets-bridge-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: gateway
{{- end -}}

{{- define "secrets-bridge-gateway.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "secrets-bridge-gateway.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Image reference. A digest pin (`image.digest`, sha256:...) wins over
`image.tag`. Mirrors secrets-bridge-agent.image.
*/}}
{{- define "secrets-bridge-gateway.image" -}}
{{- $registry := default "" .Values.global.imageRegistry -}}
{{- $repo := ternary (printf "%s/%s" $registry .Values.image.repository) .Values.image.repository (ne $registry "") -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repo .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}
{{- end -}}

{{/*
Pinned-image allow-lists. Same patterns as the agent and control-plane
charts; keep them in sync.
*/}}
{{- define "secrets-bridge-gateway.pinnedTagRegex" -}}
^(v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?|sha-[0-9a-f]{7,64})$
{{- end -}}

{{- define "secrets-bridge-gateway.digestRegex" -}}
^sha256:[0-9a-f]{64}$
{{- end -}}

{{- define "secrets-bridge-gateway.chartDevVersionRegex" -}}
^v?[0-9]+\.[0-9]+\.[0-9]+-dev\.
{{- end -}}

{{/* Connector names, application ids and app namespaces: DNS labels. */}}
{{- define "secrets-bridge-gateway.dnsLabelRegex" -}}
^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$
{{- end -}}

{{/* Argo CD AppProject and Application names: Kubernetes object names. */}}
{{- define "secrets-bridge-gateway.objectNameRegex" -}}
^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$
{{- end -}}

{{/* An IPv4 or IPv6 CIDR, loosely; the API server checks the rest. */}}
{{- define "secrets-bridge-gateway.cidrRegex" -}}
^[0-9a-fA-F:.]+/[0-9]{1,3}$
{{- end -}}

{{/* Fixed in-container paths. */}}
{{- define "secrets-bridge-gateway.identityDir" -}}/etc/secrets-bridge/gateway/identity{{- end -}}
{{- define "secrets-bridge-gateway.configDir" -}}/etc/secrets-bridge/gateway/config{{- end -}}
{{- define "secrets-bridge-gateway.cpCADir" -}}/etc/secrets-bridge/gateway/cp-ca{{- end -}}
{{- define "secrets-bridge-gateway.argocdDir" -}}/etc/secrets-bridge/gateway/argocd{{- end -}}
{{- define "secrets-bridge-gateway.argocdCADir" -}}/etc/secrets-bridge/gateway/argocd-ca{{- end -}}

{{- define "secrets-bridge-gateway.identityFile" -}}
{{- printf "%s/identity.json" (include "secrets-bridge-gateway.identityDir" .) -}}
{{- end -}}

{{- define "secrets-bridge-gateway.connectorsFile" -}}
{{- printf "%s/connectors.json" (include "secrets-bridge-gateway.configDir" .) -}}
{{- end -}}

{{- define "secrets-bridge-gateway.localAddr" -}}
{{- printf "127.0.0.1:%d" (int .Values.localPort) -}}
{{- end -}}

{{/*
The connectors file (SB_GATEWAY_CONNECTORS_FILE): a JSON array of
{name, kind, settings} in the shape internal/connectors and
internal/connectors/argocd decode. It holds URLs, allowlists and file
paths only. Tokens stay in their Secrets and reach the pod as files.
*/}}
{{- define "secrets-bridge-gateway.connectorsJSON" -}}
{{- $out := list -}}
{{- range $c := .Values.connectors.argocd -}}
{{- $s := dict "base_url" $c.baseURL "token_file" (printf "%s/%s/token" (include "secrets-bridge-gateway.argocdDir" $) $c.name) "allowed_projects" $c.allowedProjects -}}
{{- if and $c.caSecret $c.caSecret.name -}}
{{- $_ := set $s "ca_file" (printf "%s/%s/ca.crt" (include "secrets-bridge-gateway.argocdCADir" $) $c.name) -}}
{{- end -}}
{{- with $c.tlsServerName -}}
{{- $_ := set $s "tls_server_name" . -}}
{{- end -}}
{{- with $c.timeout -}}
{{- $_ := set $s "timeout" . -}}
{{- end -}}
{{- $apps := list -}}
{{- range $a := $c.applications -}}
{{- $app := dict "id" $a.id "name" $a.name -}}
{{- with $a.appNamespace -}}
{{- $_ := set $app "app_namespace" . -}}
{{- end -}}
{{- $apps = append $apps $app -}}
{{- end -}}
{{- $_ := set $s "applications" $apps -}}
{{- $out = append $out (dict "name" $c.name "kind" "argocd" "settings" $s) -}}
{{- end -}}
{{- toPrettyJson $out -}}
{{- end -}}
