<p align="center">
  <a href="https://github.com/secrets-bridge"><img src="https://raw.githubusercontent.com/secrets-bridge/.github/main/profile/logo.svg" alt="Secrets Bridge" width="520" /></a>
</p>

<p align="center">
  <b>The brain behind your secrets.</b><br/>
  Helm charts for the Secrets Bridge platform.<br/>
  <a href="https://secrets-bridge.io">secrets-bridge.io</a> · <a href="https://github.com/secrets-bridge">all repos</a>
</p>

---

# secrets-bridge / charts

Two Helm charts, deployed to two different cluster boundaries.

| Chart | Where it runs | What it bundles |
|---|---|---|
| [**`secrets-bridge/`**](./secrets-bridge/) | **Control-plane cluster** (one per platform install) | `api` + `ui` + `worker` + `controller`, sharing one Ingress |
| [**`agent/`**](./agent/) | **Every workload cluster** (one per target boundary) | Outbound-only execution agent |

The split is intentional. The agent has a different lifecycle (one per workload cluster, outbound-only, no Postgres/Redis), so it ships as its own chart rather than under the umbrella.

> **Pre-v0.1.0.** Both charts and the images they reference roll on the `:dev` tag. First release will bump to `v0.1.0`. See each chart's `CHANGELOG.md` for the cut-a-release runbook. `:dev` is a moving tag, so a production control plane and every agent need a pinned image (a digest or the `sha-<commit>` tag each image build also pushes); see Safety rails below.

## Quick start: control plane

```bash
# 1. Pre-create the env Secret (operator owns it: ESO, sops,
#    sealed-secrets, terragrunt-managed; any path works). See
#    secrets-bridge/README.md for the full key list per backend.
kubectl create namespace secrets-bridge
kubectl -n secrets-bridge apply -f my-env-secret.yaml

# 2. Install. AWS-KMS preset shown; `vault-transit` works the same shape.
#    env defaults to production, which only renders pinned images: a
#    digest (shown), a full X.Y.Z release tag or a sha-<commit> tag.
helm install secrets-bridge ./secrets-bridge \
  --namespace secrets-bridge \
  --set ingress.host=secrets-bridge.example.com \
  --set kms.backend=aws-kms \
  --set kms.awsKms.region=us-east-1 \
  --set kms.awsKms.keyId=alias/sb-wrap \
  --set api.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::123456789012:role/secrets-bridge-api \
  --set api.image.digest=sha256:<api-digest> \
  --set ui.image.digest=sha256:<ui-digest> \
  --set worker.image.digest=sha256:<worker-digest> \
  --set controller.image.digest=sha256:<controller-digest>
```

The control plane comes up behind a single Ingress: the SPA at `/` and the api at `/api/v1`. Same-origin, no CORS, one TLS cert. `/healthz`, `/readyz` and `/metrics` are not routed by the ingress (`ingress.apiPaths` defaults to `/api` only); scrape and probe them in-cluster, see [`secrets-bridge/README.md`](./secrets-bridge/README.md#metrics--health-checks).

## Quick start: agent

Agents onboard with a one-time enrollment token. Direct mint (`POST /api/v1/agents`) returns 403 unless the control plane runs with `SB_ALLOW_DIRECT_AGENT_MINT=true`, a break-glass switch that stays off.

```bash
# 1. On the CP, an admin with agent.mint creates a one-time token for the
#    provider connection this agent will serve.
curl -X POST https://secrets-bridge.example.com/api/v1/provider-connections/<connection-id>/agent-enrollment-token \
  -H "Authorization: Bearer $SB_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"expected_cluster_name":"prod-eu","expected_provider_type":"vault"}'
# → { "enrollment_token": "...", "expires_at": "...", ... }

# 2. Put the token in a Secret in the WORKLOAD cluster.
kubectl create namespace secrets-bridge
kubectl -n secrets-bridge create secret generic secrets-bridge-agent-enroll \
  --from-literal=enrollment_token=<token>

# 3. Install. On first boot the agent trades the token at
#    POST /api/v1/agents/enroll and keeps its credential on the PVC.
helm install agent ./agent \
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

## Safety rails (rendered before any pod boots)

Both charts trip render-time errors on misconfigurations that would otherwise produce a `CrashLoopBackOff` later:

| Guard | Where | Behaviour |
|---|---|---|
| `kms.backend=local` + `env=production` | `secrets-bridge` | `helm install` fails at template time citing [charts#2](https://github.com/secrets-bridge/charts/issues/2) / [api#29](https://github.com/secrets-bridge/api/issues/29) |
| `env` not exactly `dev` or `production` (case-sensitive, so `Production` fails too) | `secrets-bridge` | fails template time |
| `kms.backend` not exactly `local`, `vault-transit` or `aws-kms` (case-sensitive) | `secrets-bridge` | fails template time |
| `env=production` and an enabled component's image isn't pinned (digest, `X.Y.Z` / `vX.Y.Z`, or `sha-<hex>`; `dev`, `latest`, `main`, `X.Y`, `X` are refused) | `secrets-bridge` | fails template time |
| Image isn't pinned the same way, and `image.allowMutableTag=true` (dev only) isn't set | `agent` | fails template time |
| `image.digest` that isn't a bare `sha256:<64 hex>` | both | fails template time |
| `cp.endpoint=http://` without `cp.insecureTransport=true` | `agent` | fails template time |
| Missing `clusterName` / `cp.endpoint` / `identity.existingSecret` | `agent` | fails template time |
| Vault Kubernetes auth with `serviceAccount.automountServiceAccountToken=false` | `agent` | fails template time |

## Pod rollout on Secret rotation

Both charts default `secrets.reloader.enabled=true` (CP umbrella) and `reloader.enabled=true` (agent), and stamp `secret.reloader.stakater.com/reload: "<secret-name>"` on every Deployment that envFrom's a Secret. Install [stakater/reloader](https://github.com/stakater/Reloader) once per cluster and ESO-driven Secret refreshes propagate to a pod restart within ~30s.

## Versioning

| Tag scheme | Chart | Image |
|---|---|---|
| `:dev` (rolling) | every push to `main` | every push to `main` (per-image `docker-publish.yml`) |
| `:vX.Y.Z` | git tag `v*.*.*` on this repo | git tag `v*.*.*` on each app repo |
| `:vX.Y` | track alias | track alias |
| `:latest` | only on non-prerelease `v*.*.*` tags | only on non-prerelease `v*.*.*` tags |

## Repository layout

```
charts/
├── README.md                                 (this file)
├── secrets-bridge/                           Control-plane umbrella chart
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── README.md                             Full operator reference
│   └── templates/
│       ├── _helpers.tpl
│       ├── _validation.tpl                   Render-time safety rails
│       ├── NOTES.txt
│       ├── ingress.yaml                      SHARED: single Ingress, path priority
│       ├── api/                              Deployment + Service + SA + PDB + HPA
│       ├── ui/                               Deployment + Service + SA + PDB
│       ├── worker/                           Deployment + SA + PDB (no Service; pod-IP probes)
│       └── controller/                       CRD + Deployment + Service + SA + ClusterRole(+Binding) + Role(+Binding)
│
└── agent/                                    Workload-cluster install
    ├── Chart.yaml                            chart name: secrets-bridge-agent
    ├── values.yaml
    ├── README.md
    └── templates/
        ├── _helpers.tpl
        ├── _validation.tpl                   clusterName + cp.endpoint + identity + pinned image required
        ├── deployment.yaml                   outbound HTTPS, envFrom identity Secret, optional CA mount
        ├── serviceaccount.yaml               IRSA-friendly slot
        ├── networkpolicy.yaml                opt-in egress-only (ingress: [])
        ├── pdb.yaml
        └── NOTES.txt
```

## Operator references

- **Full operator docs:** [`secrets-bridge/README.md`](./secrets-bridge/README.md) (CP), [`agent/README.md`](./agent/README.md) (agent)
- **Doc site:** https://secrets-bridge.io. Recent additions: [Project environments](https://secrets-bridge.io/operations/project-environments/) + [Policy templates](https://secrets-bridge.io/operations/policy-templates/) (Slice L6)
- **Platform overview:** https://github.com/secrets-bridge
- **Release-process runbook:** each chart's `CHANGELOG.md`
- **Slice log:** [`secrets-bridge/skills/PROGRESS.md`](https://github.com/secrets-bridge/skills/blob/main/PROGRESS.md). Recent chart-relevant values: `api.config.mfa.{requireMFAAtLogin,totpIssuer,webauthn.*}` (Slice J + K), `api.config.oidc.trustAmrForMFA` (Slice J)

## Compatibility

- Kubernetes ≥ 1.27
- Helm ≥ 3.13
- (Optional, recommended) [stakater/reloader](https://github.com/stakater/Reloader) cluster-wide install for Secret-rotation rollouts

## License

Apache-2.0
