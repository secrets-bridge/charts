#!/usr/bin/env bash
# Enroll an agent and write its credentials straight into a Kubernetes
# Secret, without a file on disk. Run it on a trusted workstation inside
# your boundary, with kubectl pointed at the workload cluster.
#
# The one-time token is read at a silent prompt and handed to the CLI on
# stdin, so it never appears in shell history, the process list or argv.
# The bundle (agent_id, agent_secret, private_key, public_key_fingerprint)
# goes from the CLI's stdout to kubectl's stdin. Nothing secret is printed.
#
# Then install the chart with identity.existingSecret=secrets-bridge-agent-identity
# (see values.yaml next to this script).
set -euo pipefail

NAMESPACE=${NAMESPACE:-secrets-bridge}
SECRET_NAME=${SECRET_NAME:-secrets-bridge-agent-identity}
CP_ENDPOINT=${CP_ENDPOINT:?set CP_ENDPOINT, e.g. https://secrets-bridge.example.com}
CLUSTER_NAME=${CLUSTER_NAME:?set CLUSTER_NAME, e.g. prod-eu}
PROVIDER_TYPE=${PROVIDER_TYPE:-vault}

read -rsp 'Enrollment token: ' SB_ENROLL_TOKEN
echo >&2

printf '%s' "$SB_ENROLL_TOKEN" \
  | secrets-bridge-agent enroll \
      --cp-endpoint "$CP_ENDPOINT" \
      --token-file - \
      --name "$CLUSTER_NAME-agent" \
      --cluster-name "$CLUSTER_NAME" \
      --provider-type "$PROVIDER_TYPE" \
      --format env \
      --output - \
  | kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
      --from-env-file=/dev/stdin
unset SB_ENROLL_TOKEN
