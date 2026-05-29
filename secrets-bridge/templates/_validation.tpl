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
