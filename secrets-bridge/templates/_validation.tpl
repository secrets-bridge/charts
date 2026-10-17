{{/*
Fail-fast guards. Render-time `fail` calls surface a clear error
during `helm install` / `helm upgrade` BEFORE the api binary tries
to boot — operators see the misconfiguration locally instead of
waiting for a CrashLoopBackOff in the cluster.

Closes charts#2 (P0-4): the chart MUST NOT default to LocalKMS
in production-mode deployments.
*/}}

{{- define "secrets-bridge.validateKMS" -}}
{{- /*
  Exact, case-sensitive matches (CHT-N-05). The api and worker compare
  SB_ENV and SB_KMS_BACKEND byte for byte, so `Production` or `AWS-KMS`
  used to render fine here and then crash-loop at boot.
*/ -}}
{{- if not (has .Values.env (list "dev" "production")) -}}
{{- fail (printf "secrets-bridge: env=%q is not recognised (allowed: dev, production; values are case-sensitive)" .Values.env) -}}
{{- end -}}

{{- if not (has .Values.kms.backend (list "local" "vault-transit" "aws-kms")) -}}
{{- fail (printf "secrets-bridge: kms.backend=%q is not recognised (allowed: local, vault-transit, aws-kms; values are case-sensitive)" .Values.kms.backend) -}}
{{- end -}}

{{- if and (eq .Values.env "production") (eq .Values.kms.backend "local") -}}
{{- fail (printf "secrets-bridge: kms.backend=%q is not permitted when env=%q. Set kms.backend to one of: vault-transit, aws-kms. (See charts#2 / api#29.)" .Values.kms.backend .Values.env) -}}
{{- end -}}

{{- if eq .Values.kms.backend "vault-transit" -}}
{{- if and (not .Values.kms.vaultTransit.key) (not .Values.secrets.existingSecret) -}}
{{- fail "secrets-bridge: kms.backend=vault-transit requires either kms.vaultTransit.key (set explicitly) OR secrets.existingSecret (pre-baked SB_KMS_VAULT_KEY)." -}}
{{- end -}}
{{- end -}}

{{- if eq .Values.kms.backend "aws-kms" -}}
{{- if and (not .Values.kms.awsKms.region) (not .Values.secrets.existingSecret) -}}
{{- fail "secrets-bridge: kms.backend=aws-kms requires either kms.awsKms.region (set explicitly) OR secrets.existingSecret (pre-baked SB_KMS_AWS_REGION)." -}}
{{- end -}}
{{- if and (not .Values.kms.awsKms.keyId) (not .Values.secrets.existingSecret) -}}
{{- fail "secrets-bridge: kms.backend=aws-kms requires either kms.awsKms.keyId (set explicitly) OR secrets.existingSecret (pre-baked SB_KMS_AWS_KEY_ID)." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Image pin guard (CHT-03 / M11, tightened by CHT-N-02). With no
`image.tag` override, every component resolves to `.Chart.AppVersion`.
In this repo and in every chart published from `main` that's the
literal string "dev", i.e. whatever `main` last pushed; a chart published
from a `vX.Y.Z` tag defaults to `X.Y.Z` (chart-publish.yml checks that
every default image has it, charts#31). The app repos also publish
`main`, `X.Y` and `X` tags that move on every push or release, so under
env=production a tag is accepted only when it is on an allow-list of
pinned shapes (see `secrets-bridge.pinnedTagRegex`) and isn't a chart
dev version (`secrets-bridge.chartDevVersionRegex`). `image.digest` (an
exact manifest pin) bypasses the tag check; it must be a bare
`sha256:<64 hex>` value in every env, because the chart renders it as
`<repo>@<digest>`.
*/}}
{{- define "secrets-bridge.validateImageTags" -}}
{{- $components := dict "api" .Values.api "ui" .Values.ui "worker" .Values.worker "controller" .Values.controller -}}
{{- range $name, $spec := $components -}}
{{- if $spec.enabled -}}
{{- $digest := toString (default "" $spec.image.digest) -}}
{{- if $digest -}}
{{- if not (regexMatch (include "secrets-bridge.digestRegex" $) $digest) -}}
{{- fail (printf "secrets-bridge: %s.image.digest=%q is not a digest. Set it to the bare sha256:<64 hex> value (no repository, no @); the chart renders <repository>@<digest> itself." $name $digest) -}}
{{- end -}}
{{- else if eq $.Values.env "production" -}}
{{- $tag := toString (default $.Chart.AppVersion $spec.image.tag) -}}
{{- if or (not (regexMatch (include "secrets-bridge.pinnedTagRegex" $) $tag)) (regexMatch (include "secrets-bridge.chartDevVersionRegex" $) $tag) -}}
{{- fail (printf "secrets-bridge: %s.image resolves to tag %q, which is not a pinned image under env=production. Set %s.image.digest to a bare sha256:<64 hex> digest (preferred), or %s.image.tag to a full release version (X.Y.Z or vX.Y.Z, optional -prerelease) or an immutable sha-<hex> build tag. Moving tags such as dev, latest, main, X.Y and X are refused, and so are chart dev versions (X.Y.Z-dev.<sha>), which no image is tagged with." $name $tag $name $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Allow-lists shared by the image pin guard. Kept in sync with
`secrets-bridge-agent.pinnedTagRegex` / `.digestRegex` in the agent chart.

Tags: a full semver release (`1.2.3`, `v1.2.3`, `1.2.3-rc.1`) or the
`sha-<short or full commit>` tag every app repo's docker-publish
workflow pushes. Digests: `sha256:` plus 64 lowercase hex characters.
*/}}
{{- define "secrets-bridge.pinnedTagRegex" -}}
^(v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?|sha-[0-9a-f]{7,64})$
{{- end -}}

{{- define "secrets-bridge.digestRegex" -}}
^sha256:[0-9a-f]{64}$
{{- end -}}

{{/*
`X.Y.Z-dev.<sha>` is the version chart-publish.yml gives a chart built
from `main`, and the `<sha>` is a commit in this repo. It matches
`pinnedTagRegex` as a semver prerelease, but no image is tagged with it.
Charts published before charts#31 used it as appVersion, so refuse it
explicitly: a chart version copied into `image.tag`, or the same publish
mistake again, then fails the render instead of passing as a pin.
*/}}
{{- define "secrets-bridge.chartDevVersionRegex" -}}
^v?[0-9]+\.[0-9]+\.[0-9]+-dev\.
{{- end -}}

{{/*
OIDC validation (Slice F). Mirrors the api binary's boot-time
checks so misconfiguration surfaces at `helm install` rather than
CrashLoopBackOff. The api refuses to start when SB_OIDC_ISSUER is
set without SB_OIDC_CLIENT_ID + SB_OIDC_REDIRECT_URL; the chart
fail-fasts on the same conditions plus a sanity check on the
groupMap shape (keys + values must be non-empty strings — the api
binary's ValidateOIDCGroupMap rejects anything else).
*/}}
{{- define "secrets-bridge.validateOIDC" -}}
{{- $oidc := .Values.api.config.oidc -}}
{{- if $oidc.issuer -}}
{{- if not $oidc.clientId -}}
{{- fail "secrets-bridge: api.config.oidc.issuer is set but api.config.oidc.clientId is empty. Both are required to mount the OIDC routes." -}}
{{- end -}}
{{- if not $oidc.redirectUrl -}}
{{- fail "secrets-bridge: api.config.oidc.issuer is set but api.config.oidc.redirectUrl is empty. Set it to the public callback URL registered with the IdP." -}}
{{- end -}}
{{- end -}}
{{- /*
  groupMap shape check — empty map is fine (the reconciler
  short-circuits). Non-empty entries must carry non-empty
  string keys + string values.
*/ -}}
{{- range $group, $role := $oidc.groupMap -}}
{{- if not $group -}}
{{- fail "secrets-bridge: api.config.oidc.groupMap contains an empty group name. Every key must be a non-empty IdP group identifier." -}}
{{- end -}}
{{- if not (kindIs "string" $role) -}}
{{- fail (printf "secrets-bridge: api.config.oidc.groupMap[%q] must be a string (a Secrets Bridge role name), got %v" $group $role) -}}
{{- end -}}
{{- if not $role -}}
{{- fail (printf "secrets-bridge: api.config.oidc.groupMap[%q] must be a non-empty Secrets Bridge role name." $group) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
MFA validation (Slice J). Mirrors the api binary's
WebAuthnConfig.Validate at the chart layer: WebAuthn is gated on
BOTH rpId AND rpOrigins. Setting one without the other is almost
certainly a configuration mistake (the api logs the error and runs
WebAuthn-disabled, but the operator deserves a fail-fast at install).
TOTP has no required fields — the issuer always defaults.

Hard rule on rpOrigins: every entry MUST be a fully-qualified
origin (scheme + host[+port]). The browser refuses the ceremony
when the origin doesn't match the list; bare hostnames silently
break every WebAuthn attempt in the field, so we reject them at
helm install time.
*/}}
{{- define "secrets-bridge.validateMFA" -}}
{{- $mfa := .Values.api.config.mfa -}}
{{- if $mfa -}}
{{- $w := $mfa.webauthn -}}
{{- if and $w.rpId (not $w.rpOrigins) -}}
{{- fail "secrets-bridge: api.config.mfa.webauthn.rpId is set but api.config.mfa.webauthn.rpOrigins is empty. Both are required to mount the WebAuthn enrollment + assertion routes." -}}
{{- end -}}
{{- if and $w.rpOrigins (not $w.rpId) -}}
{{- fail "secrets-bridge: api.config.mfa.webauthn.rpOrigins is set but api.config.mfa.webauthn.rpId is empty. Both are required to mount the WebAuthn enrollment + assertion routes." -}}
{{- end -}}
{{- range $i, $origin := ($w.rpOrigins | default list) -}}
{{- if not (kindIs "string" $origin) -}}
{{- fail (printf "secrets-bridge: api.config.mfa.webauthn.rpOrigins[%d] must be a string, got %v" $i $origin) -}}
{{- end -}}
{{- if not (or (hasPrefix "https://" $origin) (hasPrefix "http://" $origin)) -}}
{{- fail (printf "secrets-bridge: api.config.mfa.webauthn.rpOrigins[%d]=%q must be a fully-qualified origin starting with https:// or http:// — bare hostnames break the WebAuthn ceremony silently in browsers." $i $origin) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
