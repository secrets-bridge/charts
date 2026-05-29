{{/*
Fail-fast guards for the agent chart. Render-time `fail` calls
surface a clear error during `helm install` / `helm upgrade` BEFORE
the agent binary tries to boot.
*/}}

{{- define "secrets-bridge-agent.validate" -}}
{{- if not .Values.clusterName -}}
{{- fail "secrets-bridge-agent: clusterName is required — set it to a stable identifier (e.g. \"prod-eu\"); the discovery flow uses it to disambiguate refs per cluster (BRD: one agent ≡ one cluster)." -}}
{{- end -}}

{{- if not .Values.cp.endpoint -}}
{{- fail "secrets-bridge-agent: cp.endpoint is required — set it to the HTTPS URL of the control plane (e.g. \"https://secrets-bridge.example.com\")." -}}
{{- end -}}

{{- if not .Values.identity.existingSecret -}}
{{- fail "secrets-bridge-agent: identity.existingSecret is required — pre-create the Secret in the workload cluster carrying SB_AGENT_ID and SB_AGENT_SECRET from the CP mint response." -}}
{{- end -}}

{{- if and (hasPrefix "http://" .Values.cp.endpoint) (not .Values.cp.insecureTransport) -}}
{{- fail (printf "secrets-bridge-agent: cp.endpoint=%q is plain HTTP. The chart REFUSES to render unless cp.insecureTransport=true — and that flag should only be flipped for local dev." .Values.cp.endpoint) -}}
{{- end -}}

{{- if and (not (or (hasPrefix "http://" .Values.cp.endpoint) (hasPrefix "https://" .Values.cp.endpoint))) -}}
{{- fail (printf "secrets-bridge-agent: cp.endpoint=%q is not an http(s) URL." .Values.cp.endpoint) -}}
{{- end -}}
{{- end -}}
