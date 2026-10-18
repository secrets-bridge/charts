# secrets-bridge-agent

Helm chart for the **Secrets Bridge agent** — the outbound execution agent deployed inside each workload cluster / target boundary. Distinct chart from `secrets-bridge/` (the control-plane install) because the agent has a fundamentally different lifecycle: one agent per cluster, outbound-only, no Postgres / no Redis.

> Pre-v0.1.0, the chart and the image both roll on `:dev`, and every chart published from `main` defaults the image to the `:dev` tag. First release will bump both to `v0.1.0`. The chart won't render `:dev` (or any moving tag) unless `image.allowMutableTag=true`; pin a `sha-<commit>` tag or a digest instead.

## Boot sequence

```
operator → CP:   POST {CP}/api/v1/provider-connections/<id>/agent-enrollment-token
                 → { enrollment_token }   (one-time, expires)
operator → K8s:  creates Secret { enrollment_token }
helm install:    chart deploys the agent with a PVC for its identity file
agent pod:       first boot: POST {CP}/api/v1/agents/enroll with the token
                 → stores { agent_id, agent_secret } on the PVC
                 → heartbeats CP outbound on HTTPS → claims jobs
                 → fetches values from the local provider → posts
                   results back, all OUTBOUND.
```

Direct mint (`POST /api/v1/agents`) returns 403 unless the control plane runs with `SB_ALLOW_DIRECT_AGENT_MINT=true`, a break-glass switch that stays off, so enrollment is the supported path.

## TL;DR

```bash
# 1. On the CP, an admin with agent.mint creates a one-time token for the
#    provider connection this agent will serve.
curl -X POST https://secrets-bridge.example.com/api/v1/provider-connections/<connection-id>/agent-enrollment-token \
  -H "Authorization: Bearer $SB_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"expected_cluster_name":"prod-eu","expected_provider_type":"vault"}'
# → { "enrollment_token": "...", "expires_at": "...", ... }

# 2. Put the token in a Secret in the workload cluster.
kubectl create namespace secrets-bridge
kubectl -n secrets-bridge create secret generic secrets-bridge-agent-enroll \
  --from-literal=enrollment_token=<token>

# 3. Install the chart. Pin the image (digest shown; a full X.Y.Z or a
#    sha-<commit> tag also works).
helm install agent ./charts/agent \
  --namespace secrets-bridge \
  --set clusterName=prod-eu \
  --set cp.endpoint=https://secrets-bridge.example.com \
  --set image.digest=sha256:<agent-digest> \
  --set enrollment.enabled=true \
  --set enrollment.tokenSecretName=secrets-bridge-agent-enroll \
  --set identity.mode=file \
  --set identity.persistence.enabled=true \
  --set agent.providerType=vault \
  --set providers.vault.enabled=true \
  --set providers.vault.addr=http://vault.svc.cluster.local:8200 \
  --set providers.vault.kubernetesRole=secrets-bridge-agent
```

`agent.providerType` and `clusterName` must match the token's provider connection and its `expected_*` fields, or enrollment is refused.

## Hard rules baked into this chart

| Rule | How enforced |
|---|---|
| No Postgres / Redis env vars surfaced | Chart never references DATABASE_URL / REDIS_URL — matches the agent repo's `no-db-or-redis` CI guard |
| No inbound listener | No Service rendered; the default NetworkPolicy sets `ingress: []`. The probe listener binds `bindAddress` (default `0.0.0.0:8090`) so the kubelet can reach it on the pod IP; set `bindAddress: 127.0.0.1` plus `exec` probes for loopback-only (needs an image with a shell) |
| Pinned image | The image must be a digest, a full `X.Y.Z` / `vX.Y.Z` tag or a `sha-<hex>` tag. Moving tags (`dev`, `latest`, `main`, `X.Y`, `X`) and chart dev versions (`X.Y.Z-dev.<sha>`, which no image is tagged with) fail template-time unless `image.allowMutableTag=true` (local dev only) |
| No ServiceAccount token unless needed | `automountServiceAccountToken` is off on the SA and the pod unless Vault Kubernetes auth is configured, which reads the token from `/var/run/secrets/kubernetes.io/serviceaccount/token` |
| Identity NEVER in chart values | `identity.existingSecret` references a pre-created K8s Secret. Chart values are committable; identity material is not. |
| Plain HTTP refused | `cp.endpoint=http://...` fails template-time unless `cp.insecureTransport=true` is set explicitly |
| `clusterName` required | Fails template-time without it — discovery flow needs a stable cluster identifier |
| `cp.endpoint` required | Fails template-time without it |
| Identity configured | Fails template-time unless EITHER `identity.existingSecret` (static, default) OR `enrollment.enabled=true` (file mode) |
| Agent holds no cluster-API RBAC | The chart renders no Role/RoleBinding. The agent never reads or writes Kubernetes Secrets; enrollment persists a **file** on a PVC, not a Secret |

## Identity modes

The agent's credential comes from one of two modes (`identity.mode`), 1:1 with `enrollment.enabled`:

- **`existingSecret` (chart default).** The operator pre-creates a Secret with `SB_AGENT_ID` + `SB_AGENT_SECRET`; wired via `envFrom`. No writable storage, no cluster-API access, `readOnlyRootFilesystem` stays true. Only usable when you already hold an agent credential: direct mint is disabled on the CP unless `SB_ALLOW_DIRECT_AGENT_MINT=true`.
- **`file` (enroll-on-first-boot, the onboarding path).** `enrollment.enabled=true`. An admin creates a one-time token with `POST /api/v1/provider-connections/<id>/agent-enrollment-token`; on first boot the agent exchanges it at `POST /api/v1/agents/enroll` for a persistent credential and writes it to `<identity.mountPath>/<identity.fileName>` on a **writable, restart-persistent PVC**; it reuses that credential on restart (the one-time token is spent exactly once). Requires `identity.persistence.enabled=true` (or a BYO `existingClaim`) — `emptyDir` is rejected, and a Kubernetes Secret can't back it (the agent has no Secret-write RBAC).

In file mode the chart also sets two defaults for the identity volume:

- **Update strategy.** The PVC is ReadWriteOnce, so the Deployment uses a RollingUpdate with `maxSurge: 0` and `maxUnavailable: 100%`: the old pod is scaled down before the new one is created, and a rollout never waits on a surge pod that can't attach the volume. It is not `type: Recreate` because server-side apply (Argo CD `ServerSideApply=true`, Flux, `kubectl apply --server-side`) keeps the defaulted `rollingUpdate` block on an existing Deployment, and the API server rejects that block under `Recreate`. Override with `strategy`.
- **`fsGroupChangePolicy: OnRootMismatch`** in the pod `securityContext` (when `fsGroup` is set), so kubelet stops re-adding group bits to the identity and key files on every mount. An explicit `podSecurityContext.fsGroupChangePolicy` wins.

```yaml
# Enrollment mode (Option B) — opt-in
enrollment:
  enabled: true
  tokenSecretName: my-enroll-token     # you pre-create this Secret; token is never a chart value
  tokenSecretKey: enrollment_token
identity:
  mode: file
  existingSecret: ""
  mountPath: /var/lib/secrets-bridge-agent
  fileName: identity.json
  persistence:
    enabled: true
    size: 1Gi
agent:
  providerType: aws-sm                 # must match the enrollment token's binding
  region: eu-central-1
```

The one-time token is read from a Secret you create — never render it into chart values:

```
kubectl create secret generic my-enroll-token \
  --from-literal=enrollment_token=<TOKEN-from-the-CP>
```

## Identity Secret keys (static mode)

The Secret named by `identity.existingSecret` (default `secrets-bridge-agent`) must carry:

| Key | Source |
|---|---|
| `SB_AGENT_ID` | the agent id the CP issued |
| `SB_AGENT_SECRET` | the matching agent secret (returned once) |

Optional wire-envelope keypair (Piece 8b — recommended for production):

| Key | When |
|---|---|
| `SB_AGENT_PRIVATE_KEY` | base64 X25519 private key in env (less ideal; visible in `kubectl describe pod`) |
| `SB_AGENT_PRIVATE_KEY_FILE` | path to a file the agent reads — pair with a volume mount in `extraVolumes` (future PR) |

When neither is set, the agent generates an ephemeral keypair on every boot and re-registers the public key with the CP — fine for dev, fragile for production (pod restart rotates the registered pubkey).

## TLS to the CP

Plain HTTPS to a publicly-trusted CP host needs no extra setup. For private CAs:

```yaml
cp:
  endpoint: https://sb.internal/
  caExistingSecret: cp-ca       # K8s Secret with `ca.crt` key
  tlsServerName: sb.internal     # if cert CN/SAN differs from the URL
```

The chart mounts the CA file at `/etc/secrets-bridge/cp-ca/ca.crt` and exports `SB_CP_CA_FILE` to point at it. The agent uses this CA as the EXCLUSIVE trust pool (system roots not mixed in) — defense against a compromised system CA bundle.

## Provider configuration

Credentials are NEVER chart values — they live in either:
- the identity Secret (the agent's `envFrom` will pick them up automatically), OR
- cluster-provided IRSA / Vault kube-auth, configured via the SA + service annotations.

The chart values carry only the **connection metadata** (addresses, mount paths, IRSA role hints).

### Vault

```yaml
providers:
  vault:
    enabled: true
    addr: http://vault.svc.cluster.local:8200
    kvMount: secret
    kvPrefix: prod/
    kubernetesRole: secrets-bridge-agent
```

`kvMount` and `kvPrefix` have to match the provider connection's `mount`
and `kvPrefix`. The agent pins them: a job that names a different mount or
prefix is refused (discovery and cross-team jobs always name the
connection's), and a job that names none runs against the agent's own
mount, so a mismatch can send a read or patch to the wrong mount. Leaving
`kvMount` empty means `kv`, not `secret`.

### AWS Secrets Manager (IRSA-preferred)

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/secrets-bridge-agent

providers:
  awsSecretsManager:
    enabled: true
    region: us-east-1
```

## NetworkPolicy

Default **on** (`networkPolicy.enabled=true`, CHT-06). Renders:
- `ingress: []` (hard denial of all inbound)
- DNS egress to `kube-system` pods (or a custom selector)
- TCP/443 egress, broad (any destination) when `allowCIDRs` is empty so a fresh install can reach `cp.endpoint` and its provider(s) out of the box, pinned to `allowCIDRs` once you set it

```yaml
networkPolicy:
  enabled: true            # default
  allowCIDRs:               # optional: tighten from the broad default
    - 10.42.0.10/32        # CP ingress (ALB / NLB)
    - 10.42.0.20/32        # Vault internal endpoint
```

Set `allowCIDRs` for a production install. NetworkPolicy can't match on `cp.endpoint`'s hostname, so the broad default trades a known-shaped attack surface (any HTTPS destination) for zero required operator input; pinning it down needs the CP's and your providers' actual IP ranges.

## Configuration reference

`values.yaml` is the authoritative reference. Highlights:

| Key | Required | Notes |
|---|---|---|
| `clusterName` | ✓ | Stable identifier — used by discovery |
| `cp.endpoint` | ✓ | HTTPS URL of the CP |
| `cp.insecureTransport` | | `true` allows plain HTTP — local dev only |
| `cp.caExistingSecret` | | Pin TLS to a private CA |
| `identity.existingSecret` | static mode | Pre-created K8s Secret with `SB_AGENT_ID` + `SB_AGENT_SECRET` |
| `enrollment.enabled` + `enrollment.tokenSecretName` | enrollment | One-time token Secret; pair with `identity.mode=file` + `identity.persistence.enabled=true` |
| `providers.vault.enabled` | | Wire Vault env |
| `providers.awsSecretsManager.enabled` | | Wire AWS env (IRSA-preferred) |
| `reloader.enabled` | | (default true) restart pod on identity-Secret rotation |
| `networkPolicy.enabled` | | (default true) egress-only NetworkPolicy |
| `image.digest` / `image.tag` | ✓ (one of) | Bare `sha256:<64 hex>` digest (overrides `image.tag`), or a full `X.Y.Z` / `vX.Y.Z` / `sha-<hex>` tag |
| `image.allowMutableTag` | | `true` renders a moving tag (default `:dev`, `main`, ...). Local dev only |
| `serviceAccount.automountServiceAccountToken` | | `null` (default) = on only for Vault Kubernetes auth; `true`/`false` override |

## License

Apache-2.0
