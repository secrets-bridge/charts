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
{{- fail "secrets-bridge-agent: identity.existingSecret is required in static mode — pre-create the Secret carrying SB_AGENT_ID + SB_AGENT_SECRET, or use enrollment instead (enrollment.enabled=true, identity.mode=file) with a token from POST /api/v1/provider-connections/<id>/agent-enrollment-token." -}}
{{- end -}}
{{- else -}}
{{- if not .Values.enrollment.tokenSecretName -}}
{{- fail "secrets-bridge-agent: enrollment.enabled=true requires enrollment.tokenSecretName — pre-create a Secret holding the one-time token under key enrollment.tokenSecretKey. Never set the token as a plaintext chart value." -}}
{{- end -}}
{{- if not (or .Values.identity.persistence.enabled .Values.identity.persistence.existingClaim) -}}
{{- fail "secrets-bridge-agent: enrollment.enabled=true requires a WRITABLE, restart-persistent identity volume — set identity.persistence.enabled=true (chart provisions a PVC) or identity.persistence.existingClaim. emptyDir is NOT acceptable: a restart would lose the credential and the one-time enrollment token cannot be reused." -}}
{{- end -}}
{{- with .Values.identity.privateKeyFileName -}}
{{- if or (contains "/" .) (eq . ".") (eq . "..") -}}
{{- fail (printf "secrets-bridge-agent: identity.privateKeyFileName=%q must be a bare file name; the key is written under identity.mountPath." .) -}}
{{- end -}}
{{- if eq . $.Values.identity.fileName -}}
{{- fail (printf "secrets-bridge-agent: identity.privateKeyFileName=%q must differ from identity.fileName; the private key and the enrolled credential are separate files." .) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- if and (hasPrefix "http://" .Values.cp.endpoint) (not .Values.cp.insecureTransport) -}}
{{- fail (printf "secrets-bridge-agent: cp.endpoint=%q is plain HTTP. The chart REFUSES to render unless cp.insecureTransport=true — and that flag should only be flipped for local dev." .Values.cp.endpoint) -}}
{{- end -}}

{{- if and (not (or (hasPrefix "http://" .Values.cp.endpoint) (hasPrefix "https://" .Values.cp.endpoint))) -}}
{{- fail (printf "secrets-bridge-agent: cp.endpoint=%q is not an http(s) URL." .Values.cp.endpoint) -}}
{{- end -}}

{{- /*
  Image pin guard (CHT-N-01). The control-plane chart enforces pinning
  under env=production; this chart has no env value, so pinning is
  enforced on every install and `image.allowMutableTag: true` is the
  explicit, dev-only way out. The default tag is .Chart.AppVersion:
  "dev" (rebuilt on every push to main) in this repo and in every
  chart published from main, so a default install of those has to
  choose a pin or the escape hatch. A chart published from a vX.Y.Z
  tag defaults to X.Y.Z, which chart-publish.yml checks exists
  (charts#31). Chart dev versions (X.Y.Z-dev.<sha>) are refused even
  though they look like a semver prerelease; see
  secrets-bridge-agent.chartDevVersionRegex.
*/ -}}
{{- $digest := toString (default "" .Values.image.digest) -}}
{{- if $digest -}}
{{- if not (regexMatch (include "secrets-bridge-agent.digestRegex" .) $digest) -}}
{{- fail (printf "secrets-bridge-agent: image.digest=%q is not a digest. Set it to the bare sha256:<64 hex> value (no repository, no @); the chart renders <repository>@<digest> itself." $digest) -}}
{{- end -}}
{{- else if ne (toString .Values.image.allowMutableTag) "true" -}}
{{- $tag := toString (default .Chart.AppVersion .Values.image.tag) -}}
{{- if or (not (regexMatch (include "secrets-bridge-agent.pinnedTagRegex" .) $tag)) (regexMatch (include "secrets-bridge-agent.chartDevVersionRegex" .) $tag) -}}
{{- fail (printf "secrets-bridge-agent: image resolves to tag %q, which is not a pinned image. Set image.digest to a bare sha256:<64 hex> digest (preferred), or image.tag to a full release version (X.Y.Z or vX.Y.Z, optional -prerelease) or an immutable sha-<hex> build tag. Moving tags such as dev, latest, main, X.Y and X are refused, and so are chart dev versions (X.Y.Z-dev.<sha>), which no image is tagged with; for local dev only, set image.allowMutableTag=true." $tag) -}}
{{- end -}}
{{- end -}}

{{- /*
  Vault Kubernetes auth reads the ServiceAccount token from the
  standard projected path, so it can't work with the token switched
  off (CHT-N-06). Fail here instead of at the first Vault login.
*/ -}}
{{- if and (include "secrets-bridge-agent.vaultKubernetesAuth" .) (eq (include "secrets-bridge-agent.automountServiceAccountToken" .) "false") -}}
{{- fail "secrets-bridge-agent: providers.vault.kubernetesRole is set (Vault Kubernetes auth) but serviceAccount.automountServiceAccountToken=false. The agent reads the ServiceAccount token from /var/run/secrets/kubernetes.io/serviceaccount/token to log in to Vault; leave automountServiceAccountToken unset (auto) or set it to true." -}}
{{- end -}}
{{- end -}}
