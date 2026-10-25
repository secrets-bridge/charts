# secrets-bridge-agent

Helm chart for the **Secrets Bridge agent**, the outbound execution agent deployed inside each workload cluster / target boundary. Distinct chart from `secrets-bridge/` (the control-plane install) because the agent has a fundamentally different lifecycle: one agent per cluster, outbound-only, no Postgres / no Redis.

> Pre-v0.1.0, the chart and the image both roll on `:dev`, and every chart published from `main` defaults the image to the `:dev` tag. First release will bump both to `v0.1.0`. The chart won't render `:dev` (or any moving tag) unless `image.allowMutableTag=true`; pin a `sha-<commit>` tag or a digest instead.

## How an agent gets its identity

```
admin  → CP console:  create a one-time enrollment token (agent.mint)
operator workstation: secrets-bridge-agent enroll --token-file -
                      → generates the X25519 key pair locally
                      → proves possession of the key to the CP
                      → receives agent_id + agent_secret, once
operator → store:     agent_id, agent_secret, private_key into AWS Secrets
                      Manager, Vault or a Kubernetes Secret
helm install:         identity.existingSecret=<Secret name>
agent pod:            reads /etc/secrets-bridge/agent read-only
                      → heartbeats outbound over HTTPS with its key fingerprint
                      → claims jobs, reads the local provider, posts results
```

The private key never leaves your boundary. The control plane stores only the public key and the SHA-256 of the agent secret. The X25519 key encrypts wraps sent to the agent; it is not a TLS client certificate. The agent writes nothing: no file, no PVC, no Kubernetes Secret, and it never generates a key at runtime. A restart or reschedule reads the same Secret again.

There is no other identity mode. The PVC mode and enrollment at pod start are removed (see [Upgrading from the PVC mode](#upgrading-from-the-pvc-mode)).

## TL;DR

```bash
# 1. In the console, an admin with agent.mint creates a one-time enrollment
#    token for the provider connection this agent will serve.

# 2. On a trusted workstation, enroll and write the bundle into a Secret.
#    The token goes in on stdin, the bundle out on stdout: nothing secret
#    lands in argv, shell history, a file or the terminal.
kubectl create namespace secrets-bridge
read -rsp 'Enrollment token: ' SB_ENROLL_TOKEN; echo
printf '%s' "$SB_ENROLL_TOKEN" \
  | secrets-bridge-agent enroll --cp-endpoint https://secrets-bridge.example.com \
      --token-file - --name prod-eu-agent --cluster-name prod-eu --provider-type vault \
      --format env --output - \
  | kubectl -n secrets-bridge create secret generic secrets-bridge-agent --from-env-file=/dev/stdin
unset SB_ENROLL_TOKEN

# 3. Install. Pin the image by digest.
helm install agent ./charts/agent \
  --namespace secrets-bridge \
  --set clusterName=prod-eu \
  --set cp.endpoint=https://secrets-bridge.example.com \
  --set image.digest=sha256:<agent-digest> \
  --set identity.existingSecret=secrets-bridge-agent \
  --set providers.vault.enabled=true \
  --set providers.vault.addr=https://vault.example.com \
  --set providers.vault.kubernetesRole=secrets-bridge-agent
```

`--cluster-name` and `--provider-type` must match the token's provider connection and its expected values, or enrollment is refused.

## Examples

Each example directory has a `values.yaml` for this chart. CI renders every one and validates it, and the External Secrets Operator manifests, with `kubeconform`.

| Example | Where the credential lives |
|---|---|
| [`examples/kubectl-secret/`](./examples/kubectl-secret/) | A Kubernetes Secret created by piping `enroll --format env --output -` into `kubectl create secret generic --from-env-file=/dev/stdin` (`create-secret.sh`) |
| [`examples/eso-aws-secrets-manager/`](./examples/eso-aws-secrets-manager/) | AWS Secrets Manager, written with `aws secretsmanager put-secret-value --secret-string file:///dev/stdin`, synced by an ESO `ExternalSecret` |
| [`examples/eso-vault/`](./examples/eso-vault/) | Vault KV v2, written with `vault kv put -mount=kv <path> -`, synced by an ESO `ExternalSecret` |

ESO is one way to sync the Secret, not a runtime dependency: the agent only reads the Kubernetes Secret. Never commit a Secret manifest that holds the values (for example the output of `enroll --format k8s-secret`).

## The identity Secret

`identity.existingSecret` is required. The Secret must be in the release namespace and hold:

| Key | Content |
|---|---|
| `agent_id` | The agent id the CP issued |
| `agent_secret` | The agent credential, returned once by `enroll` |
| `private_key` | Base64 of the 32-byte X25519 private key `enroll` generated |

When your secret store uses other key names, map them with `identity.keys.agentId`, `identity.keys.agentSecret` and `identity.keys.privateKey`. The chart mounts only these three keys, through `items`, under the fixed file names above. Other keys in the Secret (such as `public_key_fingerprint`) are not mounted.

How it's mounted:

- Directory `/etc/secrets-bridge/agent`, exported as `SB_AGENT_CREDENTIALS_DIR`.
- `readOnly: true`, `defaultMode: 0400` and `mode: 0400` on each item, no `subPath`.
- Secret volume files are owned by root. `podSecurityContext.fsGroup` (default `65532`, required) gives them the agent's group, and kubelet adds the group read bit, so the files show up as `0440 root:65532`. Without `fsGroup` they stay `0400 root:root` and the non-root agent can't read them. The agent refuses a file with group write or any permission for others (`mode & 0o037 != 0`), and refuses to start when a file is missing or malformed. The `agent identity mount on kind` CI job checks the modes kubelet actually produces.

The chart renders no PVC, no Role or RoleBinding, and no `envFrom`. The agent has no Kubernetes API access unless Vault Kubernetes auth needs the ServiceAccount token.

## Rotation, revoke and restarts

- **Key rotation.** An admin requests a rotation (console, or `POST /api/v1/admin/agents/<id>/key-rotation`, which needs `agent.mint` and a fresh second factor) and gets a one-time rotation token. On the workstation, `secrets-bridge-agent rotate-key` generates a new key, proves possession to the CP and prints a new bundle (same `agent_id` and `agent_secret`, new `private_key`). Write it to the same secret store entry. After ESO syncs it (or you replace the Kubernetes Secret), the agent has to restart: with `reloader.enabled=true` (default) and [stakater/reloader](https://github.com/stakater/Reloader) installed, that happens on its own; otherwise run `kubectl rollout restart deploy/<release>-secrets-bridge-agent`. Until it restarts, the agent still holds the old key and gets `409 agent_key_mismatch`.
- **Revoke.** Revoking the agent on the CP stops it at its next request (`401`). Delete the Secret and the secret store entry; enroll again with a new token for a replacement.
- **Restart or reschedule.** Reads the same Secret. Nothing is lost, because the agent keeps no local state.
- **Rollouts.** The default RollingUpdate briefly runs two pods with one identity. Set `strategy.type: Recreate` if you want no overlap.

## Upgrading from the PVC mode

Pre-release charts had an `identity.mode=file` mode in which the agent enrolled at pod start and kept its credential on a PVC. It is removed, along with `identity.persistence`, `identity.mountPath`, `identity.fileName`, `identity.privateKeyFileName`, `enrollment.*` and `agent.*`. Any of these keys fails the render: `values.schema.json` refuses it, and a template guard names it when schema validation is skipped. The old static `envFrom` Secret with `SB_AGENT_ID` and `SB_AGENT_SECRET` is no longer read either.

To move an existing install: create a new enrollment token, run `secrets-bridge-agent enroll`, store the bundle as above, drop the removed keys from your values, set `identity.existingSecret`, and upgrade. Then revoke the old agent on the CP and delete its PVC (it was kept on uninstall with `helm.sh/resource-policy: keep`).

## Hard rules baked into this chart

| Rule | How enforced |
|---|---|
| No Postgres / Redis env vars surfaced | Chart never references DATABASE_URL / REDIS_URL, which matches the agent repo's `no-db-or-redis` CI guard |
| No inbound listener | No Service rendered; the default NetworkPolicy sets `ingress: []`. The probe listener binds `bindAddress` (default `0.0.0.0:8090`) so the kubelet can reach it on the pod IP; set `bindAddress: 127.0.0.1` plus `exec` probes for loopback-only (needs an image with a shell) |
| Pinned image | The image must be a digest, a full `X.Y.Z` / `vX.Y.Z` tag or a `sha-<hex>` tag. Moving tags (`dev`, `latest`, `main`, `X.Y`, `X`) and chart dev versions (`X.Y.Z-dev.<sha>`) fail template-time unless `image.allowMutableTag=true` (local dev only) |
| No ServiceAccount token unless needed | `automountServiceAccountToken` is off on the SA and the pod unless Vault Kubernetes auth is configured |
| Identity never in chart values | `identity.existingSecret` names a Secret; values are committable, identity material is not |
| Read-only identity, no durable state | Secret mounted read-only at `/etc/secrets-bridge/agent`; no PVC, no writable volume, `readOnlyRootFilesystem: true` |
| No cluster-API RBAC | The chart renders no Role, ClusterRole or binding. The agent never reads or writes Kubernetes Secrets through the API |
| Plain HTTP refused | `cp.endpoint=http://...` fails template-time unless `cp.insecureTransport=true` |
| Required values | `clusterName`, `cp.endpoint`, `identity.existingSecret` and `podSecurityContext.fsGroup` fail template-time when missing |
| Removed values refused | The PVC and enrollment keys listed above fail the render by name |

## TLS to the CP

Plain HTTPS to a publicly-trusted CP host needs no extra setup. For private CAs:

```yaml
cp:
  endpoint: https://sb.internal/
  caExistingSecret: cp-ca       # K8s Secret with `ca.crt` key
  tlsServerName: sb.internal     # if cert CN/SAN differs from the URL
```

The chart mounts the CA file at `/etc/secrets-bridge/cp-ca/ca.crt` and exports `SB_CP_CA_FILE` to point at it. The agent uses this CA as the EXCLUSIVE trust pool (system roots not mixed in), as a defense against a compromised system CA bundle.

## Provider configuration

Provider credentials are never chart values. Use cluster-provided IRSA / EKS Pod Identity or Vault Kubernetes auth (configured through the ServiceAccount), or, for Vault token auth, name a Secret in `providers.vault.tokenSecret` (rendered as `SB_VAULT_TOKEN` from a `secretKeyRef`).

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
| `clusterName` | ✓ | Stable identifier, used by discovery |
| `cp.endpoint` | ✓ | HTTPS URL of the CP |
| `cp.insecureTransport` | | `true` allows plain HTTP, for local dev only |
| `cp.caExistingSecret` | | Pin TLS to a private CA |
| `identity.existingSecret` | ✓ | Secret with `agent_id`, `agent_secret`, `private_key`, mounted read-only at `/etc/secrets-bridge/agent` |
| `identity.keys.*` | | Secret key names when they differ from the defaults |
| `podSecurityContext.fsGroup` | ✓ (default `65532`) | Lets the non-root agent read the root-owned Secret files |
| `providers.vault.tokenSecret.name` / `.key` | | Vault token auth from an existing Secret |
| `providers.vault.enabled` | | Wire Vault env |
| `providers.awsSecretsManager.enabled` | | Wire AWS env (IRSA-preferred) |
| `reloader.enabled` | | (default true) restart the pod when the identity Secret changes |
| `networkPolicy.enabled` | | (default true) egress-only NetworkPolicy |
| `image.digest` / `image.tag` | ✓ (one of) | Bare `sha256:<64 hex>` digest (overrides `image.tag`), or a full `X.Y.Z` / `vX.Y.Z` / `sha-<hex>` tag |
| `image.allowMutableTag` | | `true` renders a moving tag (default `:dev`, `main`, ...). Local dev only |
| `serviceAccount.automountServiceAccountToken` | | `null` (default) = on only for Vault Kubernetes auth; `true`/`false` override |

## License

Apache-2.0
