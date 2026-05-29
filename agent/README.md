# secrets-bridge-agent

Helm chart for the **Secrets Bridge agent** — the outbound execution agent deployed inside each workload cluster / target boundary. Distinct chart from `secrets-bridge/` (the control-plane install) because the agent has a fundamentally different lifecycle: one agent per cluster, outbound-only, no Postgres / no Redis.

> Pre-v0.1.0 — both the chart and the image roll on the `:dev` tag. First release will bump both to `v0.1.0`.

## Boot sequence

```
operator → CP:   POST {CP}/api/v1/agents → { id, agent_secret }
operator → K8s:  creates Secret { SB_AGENT_ID, SB_AGENT_SECRET }
helm install:    chart deploys the agent, mounts the Secret
agent pod:       reads identity → heartbeats CP outbound on HTTPS
                 → claims jobs → fetches values from the local
                   provider → posts results back, all OUTBOUND.
```

## TL;DR

```bash
# 1. Mint the agent on the CP side (admin or via the UI).
curl -X POST https://secrets-bridge.example.com/api/v1/agents \
  -H 'Content-Type: application/json' \
  -d '{"name":"prod-eu","scope":{"cluster":"prod-eu"}}'
# → { "id": "...", "agent_secret": "..." }

# 2. Drop those into a Secret in the workload cluster.
kubectl create namespace secrets-bridge
kubectl -n secrets-bridge create secret generic secrets-bridge-agent \
  --from-literal=SB_AGENT_ID=<id> \
  --from-literal=SB_AGENT_SECRET=<secret>

# 3. Install the chart.
helm install agent ./charts/agent \
  --namespace secrets-bridge \
  --set clusterName=prod-eu \
  --set cp.endpoint=https://secrets-bridge.example.com \
  --set providers.vault.enabled=true \
  --set providers.vault.addr=http://vault.svc.cluster.local:8200 \
  --set providers.vault.kubernetesRole=secrets-bridge-agent
```

## Hard rules baked into this chart

| Rule | How enforced |
|---|---|
| No Postgres / Redis env vars surfaced | Chart never references DATABASE_URL / REDIS_URL — matches the agent repo's `no-db-or-redis` CI guard |
| No inbound listener | Probes loopback only (`host: 127.0.0.1`); no Service rendered; opt-in NetworkPolicy explicitly sets `ingress: []` |
| Identity NEVER in chart values | `identity.existingSecret` references a pre-created K8s Secret. Chart values are committable; identity material is not. |
| Plain HTTP refused | `cp.endpoint=http://...` fails template-time unless `cp.insecureTransport=true` is set explicitly |
| `clusterName` required | Fails template-time without it — discovery flow needs a stable cluster identifier |
| `cp.endpoint` required | Fails template-time without it |
| `identity.existingSecret` required | Fails template-time without it |

## Identity Secret keys

The Secret named by `identity.existingSecret` (default `secrets-bridge-agent`) must carry:

| Key | Source |
|---|---|
| `SB_AGENT_ID` | `id` from the CP's mint response |
| `SB_AGENT_SECRET` | `agent_secret` from the CP's mint response |

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

Opt-in via `networkPolicy.enabled=true`. Renders:
- `ingress: []` (hard denial of all inbound)
- DNS egress to `kube-system` pods (or a custom selector)
- Operator-supplied CIDRs egress on TCP/443 (provide CP ingress IP + provider VPC endpoints)

```yaml
networkPolicy:
  enabled: true
  allowCIDRs:
    - 10.42.0.10/32        # CP ingress (ALB / NLB)
    - 10.42.0.20/32        # Vault internal endpoint
```

## Configuration reference

`values.yaml` is the authoritative reference. Highlights:

| Key | Required | Notes |
|---|---|---|
| `clusterName` | ✓ | Stable identifier — used by discovery |
| `cp.endpoint` | ✓ | HTTPS URL of the CP |
| `cp.insecureTransport` | | `true` allows plain HTTP — local dev only |
| `cp.caExistingSecret` | | Pin TLS to a private CA |
| `identity.existingSecret` | ✓ | Pre-created K8s Secret with `SB_AGENT_ID` + `SB_AGENT_SECRET` |
| `providers.vault.enabled` | | Wire Vault env |
| `providers.awsSecretsManager.enabled` | | Wire AWS env (IRSA-preferred) |
| `reloader.enabled` | | (default true) restart pod on identity-Secret rotation |
| `networkPolicy.enabled` | | (default false) egress-only NetworkPolicy |

## License

Apache-2.0
