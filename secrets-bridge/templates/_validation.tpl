{{/*
Fail-fast guards. Render-time `fail` calls surface a clear error
during `helm install` / `helm upgrade` BEFORE the api binary tries
to boot — operators see the misconfiguration locally instead of
waiting for a CrashLoopBackOff in the cluster.

Closes charts#2 (P0-4): the chart MUST NOT default to LocalKMS
in production-mode deployments.
*/}}

{{- define "secrets-bridge.validateKMS" -}}
{{- if and (eq (lower .Values.env) "production") (eq (lower .Values.kms.backend) "local") -}}
{{- fail (printf "secrets-bridge: kms.backend=%q is not permitted when env=%q. Set kms.backend to one of: vault-transit, aws-kms. (See charts#2 / api#29.)" .Values.kms.backend .Values.env) -}}
{{- end -}}

{{- if eq (lower .Values.kms.backend) "vault-transit" -}}
{{- if and (not .Values.kms.vaultTransit.key) (not .Values.secrets.existingSecret) -}}
{{- fail "secrets-bridge: kms.backend=vault-transit requires either kms.vaultTransit.key (set explicitly) OR secrets.existingSecret (pre-baked SB_KMS_VAULT_KEY)." -}}
{{- end -}}
{{- end -}}

{{- if eq (lower .Values.kms.backend) "aws-kms" -}}
{{- if and (not .Values.kms.awsKms.region) (not .Values.secrets.existingSecret) -}}
{{- fail "secrets-bridge: kms.backend=aws-kms requires either kms.awsKms.region (set explicitly) OR secrets.existingSecret (pre-baked SB_KMS_AWS_REGION)." -}}
{{- end -}}
{{- if and (not .Values.kms.awsKms.keyId) (not .Values.secrets.existingSecret) -}}
{{- fail "secrets-bridge: kms.backend=aws-kms requires either kms.awsKms.keyId (set explicitly) OR secrets.existingSecret (pre-baked SB_KMS_AWS_KEY_ID)." -}}
{{- end -}}
{{- end -}}

{{- if not (has (lower .Values.env) (list "dev" "production")) -}}
{{- fail (printf "secrets-bridge: env=%q is not recognised (allowed: dev, production)" .Values.env) -}}
{{- end -}}

{{- if not (has (lower .Values.kms.backend) (list "local" "vault-transit" "aws-kms")) -}}
{{- fail (printf "secrets-bridge: kms.backend=%q is not recognised (allowed: local, vault-transit, aws-kms)" .Values.kms.backend) -}}
{{- end -}}
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
