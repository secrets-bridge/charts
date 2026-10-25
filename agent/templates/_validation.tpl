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

{{- /*
  Removed identity settings. The PVC, file mode and enroll-at-pod-start
  path is gone: the only identity is a read-only identity.existingSecret
  written by `secrets-bridge-agent enroll`. values.schema.json refuses
  these keys first; this guard names them when schema validation is
  skipped, so a stale install fails here instead of starting an agent
  that can't find its credentials.
*/ -}}
{{- $removed := dict
  "enrollment" "enrollment.* was removed: the agent no longer enrolls at pod start. Run `secrets-bridge-agent enroll` on a workstation and store its output in the Secret named by identity.existingSecret"
  "agent" "agent.* (name, providerType, region) was removed: pass them to `secrets-bridge-agent enroll` (--name, --provider-type, --region) instead"
-}}
{{- range $key, $msg := $removed -}}
{{- if hasKey $.Values $key -}}
{{- fail (printf "secrets-bridge-agent: %s. See the chart README, Upgrading from the PVC mode." $msg) -}}
{{- end -}}
{{- end -}}
{{- $identity := default (dict) .Values.identity -}}
{{- range $key := list "mode" "persistence" "inline" "mountPath" "fileName" "privateKeyFileName" -}}
{{- if hasKey $identity $key -}}
{{- fail (printf "secrets-bridge-agent: identity.%s was removed. identity.existingSecret is the only identity mode: a read-only Secret with agent_id, agent_secret and private_key, mounted at /etc/secrets-bridge/agent. No PVC, no identity file. See the chart README, Upgrading from the PVC mode." $key) -}}
{{- end -}}
{{- end -}}

{{- if not $identity.existingSecret -}}
{{- fail "secrets-bridge-agent: identity.existingSecret is required. Create a Secret with the keys agent_id, agent_secret and private_key from the output of `secrets-bridge-agent enroll` (kubectl, or External Secrets Operator from AWS Secrets Manager or Vault), then set identity.existingSecret to its name. Never put the values in chart values." -}}
{{- end -}}
{{- $keys := default (dict) $identity.keys -}}
{{- range $k := list "agentId" "agentSecret" "privateKey" -}}
{{- if not (get $keys $k) -}}
{{- fail (printf "secrets-bridge-agent: identity.keys.%s must not be empty; it names the Secret key the chart mounts." $k) -}}
{{- end -}}
{{- end -}}

{{- /*
  Secret volume files are owned by root. Without fsGroup the non-root
  agent can't read its 0400 credential files at all.
*/ -}}
{{- if not (hasKey (default (dict) .Values.podSecurityContext) "fsGroup") -}}
{{- fail "secrets-bridge-agent: podSecurityContext.fsGroup is required. The identity Secret files are owned by root, and fsGroup is what lets the non-root agent read them (kubelet shows them as 0440 root:<fsGroup>)." -}}
{{- end -}}
{{- if eq (toString .Values.podSecurityContext.fsGroup) "<nil>" -}}
{{- fail "secrets-bridge-agent: podSecurityContext.fsGroup is required. The identity Secret files are owned by root, and fsGroup is what lets the non-root agent read them (kubelet shows them as 0440 root:<fsGroup>)." -}}
{{- end -}}

{{- with .Values.providers.vault.tokenSecret -}}
{{- if and .name (not .key) -}}
{{- fail "secrets-bridge-agent: providers.vault.tokenSecret.key must not be empty when tokenSecret.name is set." -}}
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
