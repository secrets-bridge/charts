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

{{- /* Identity: static existingSecret (default) XOR enroll-on-first-boot. */ -}}
{{- $mode := .Values.identity.mode -}}
{{- $enroll := .Values.enrollment.enabled -}}
{{- if not (or (eq $mode "existingSecret") (eq $mode "file")) -}}
{{- fail (printf "secrets-bridge-agent: identity.mode=%q is invalid — must be \"existingSecret\" (static/default) or \"file\" (enrollment)." $mode) -}}
{{- end -}}
{{- /* mode and enrollment.enabled are 1:1 */ -}}
{{- if and $enroll (ne $mode "file") -}}
{{- fail "secrets-bridge-agent: enrollment.enabled=true requires identity.mode=file (a writable, persistent identity file)." -}}
{{- end -}}
{{- if and (not $enroll) (eq $mode "file") -}}
{{- fail "secrets-bridge-agent: identity.mode=file requires enrollment.enabled=true. For a pre-provisioned credential keep identity.mode=existingSecret (the live / production default)." -}}
{{- end -}}
{{- if not $enroll -}}
{{- if not .Values.identity.existingSecret -}}
{{- fail "secrets-bridge-agent: identity.existingSecret is required in static mode — pre-create the Secret carrying SB_AGENT_ID + SB_AGENT_SECRET from the CP mint response." -}}
{{- end -}}
{{- else -}}
{{- if not .Values.enrollment.tokenSecretName -}}
{{- fail "secrets-bridge-agent: enrollment.enabled=true requires enrollment.tokenSecretName — pre-create a Secret holding the one-time token under key enrollment.tokenSecretKey. Never set the token as a plaintext chart value." -}}
{{- end -}}
{{- if not (or .Values.identity.persistence.enabled .Values.identity.persistence.existingClaim) -}}
{{- fail "secrets-bridge-agent: enrollment.enabled=true requires a WRITABLE, restart-persistent identity volume — set identity.persistence.enabled=true (chart provisions a PVC) or identity.persistence.existingClaim. emptyDir is NOT acceptable: a restart would lose the credential and the one-time enrollment token cannot be reused." -}}
{{- end -}}
{{- end -}}

{{- if and (hasPrefix "http://" .Values.cp.endpoint) (not .Values.cp.insecureTransport) -}}
{{- fail (printf "secrets-bridge-agent: cp.endpoint=%q is plain HTTP. The chart REFUSES to render unless cp.insecureTransport=true — and that flag should only be flipped for local dev." .Values.cp.endpoint) -}}
{{- end -}}

{{- if and (not (or (hasPrefix "http://" .Values.cp.endpoint) (hasPrefix "https://" .Values.cp.endpoint))) -}}
{{- fail (printf "secrets-bridge-agent: cp.endpoint=%q is not an http(s) URL." .Values.cp.endpoint) -}}
{{- end -}}
{{- end -}}
