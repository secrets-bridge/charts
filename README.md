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

Three Helm charts. The control plane runs in one cluster; the agent and the optional Gateway run inside each customer boundary.

| Chart | Where it runs | What it bundles |
|---|---|---|
| [**`secrets-bridge/`**](./secrets-bridge/) | **Control-plane cluster** (one per platform install) | `api` + `ui` + `worker` + `controller`, sharing one Ingress |
| [**`agent/`**](./agent/) | **Every workload cluster** (one per target boundary) | Outbound-only execution agent |
| [**`gateway/`**](./gateway/) | **Inside a customer boundary** (optional) | Outbound-only, read-only Argo CD rollout-state observation (Release 1) |

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

Scripts authenticate with the session cookie from `POST /api/v1/auth/login`; the api reads no bearer token for users. Creating an enrollment token needs `agent.mint` and no fresh second factor. Routes that require step-up MFA refuse a session without a recent second factor (`401` with `WWW-Authenticate: step-up`), so do those in the console.

```bash
# 1. On the CP, an admin with agent.mint creates a one-time token for the
#    provider connection this agent will serve (or creates it in the
#    console). Login sets a session cookie and returns no token, so the
#    cookie goes into a private cookie jar. The password is read from the
#    terminal, not typed on the command line.
CP=https://secrets-bridge.example.com
JAR=$(mktemp) && chmod 600 "$JAR"
read -rp 'Admin email: ' SB_ADMIN_EMAIL
read -rsp 'Admin password: ' SB_ADMIN_PASSWORD; echo
jq -n --arg e "$SB_ADMIN_EMAIL" --arg p "$SB_ADMIN_PASSWORD" '{email:$e,password:$p}' \
  | curl -fsS -c "$JAR" -o /dev/null -X POST "$CP/api/v1/auth/login" \
      -H 'Content-Type: application/json' --data-binary @-
unset SB_ADMIN_PASSWORD
curl -fsS -b "$JAR" -X POST "$CP/api/v1/provider-connections/<connection-id>/agent-enrollment-token" \
  -H 'Content-Type: application/json' \
  -d '{"expected_cluster_name":"prod-eu","expected_provider_type":"vault"}'
# → { "enrollment_token": "...", "expires_at": "...", ... }
rm -f "$JAR"

# 2. Put the token in a Secret in the WORKLOAD cluster. bash or zsh:
#    paste the token at the silent prompt, then Enter. It never reaches
#    a command line, your shell history or the process list.
kubectl create namespace secrets-bridge
read -rs SB_ENROLL_TOKEN
printf '%s' "$SB_ENROLL_TOKEN" | kubectl -n secrets-bridge create secret generic secrets-bridge-agent-enroll \
  --from-file=enrollment_token=/dev/stdin
unset SB_ENROLL_TOKEN

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

## Quick start: gateway

The Gateway is optional. Release 1 observes Argo CD only, with no Kubernetes RBAC and no ServiceAccount token. Enroll it once outside the cluster, store the identity JSON and the read-only Argo CD token in Secrets, then install with a values file. See [`gateway/README.md`](./gateway/README.md) for the enrollment pipeline, the Argo CD account and a full values example.

```bash
helm install gateway ./gateway --namespace tenant-a-uat -f gateway-values.yaml
```

## Safety rails (rendered before any pod boots)

Both charts trip render-time errors on misconfigurations that would otherwise produce a `CrashLoopBackOff` later:

| Guard | Where | Behaviour |
|---|---|---|
| `kms.backend=local` + `env=production` | `secrets-bridge` | `helm install` fails at template time citing [charts#2](https://github.com/secrets-bridge/charts/issues/2) / [api#29](https://github.com/secrets-bridge/api/issues/29) |
| `env` not exactly `dev` or `production` (case-sensitive, so `Production` fails too) | `secrets-bridge` | fails template time |
| `kms.backend` not exactly `local`, `vault-transit` or `aws-kms` (case-sensitive) | `secrets-bridge` | fails template time |
| `env=production` and an enabled component's image isn't pinned (digest, `X.Y.Z` / `vX.Y.Z`, or `sha-<hex>`; `dev`, `latest`, `main`, `X.Y`, `X` and chart dev versions `X.Y.Z-dev.<sha>` are refused) | `secrets-bridge` | fails template time |
| Image isn't pinned the same way, and `image.allowMutableTag=true` (dev only) isn't set | `agent` | fails template time |
| `image.digest` that isn't a bare `sha256:<64 hex>` | both | fails template time |
| `cp.endpoint=http://` without `cp.insecureTransport=true` | `agent` | fails template time |
| Missing `clusterName` / `cp.endpoint` / `identity.existingSecret` | `agent` | fails template time |
| Vault Kubernetes auth with `serviceAccount.automountServiceAccountToken=false` | `agent` | fails template time |
| Unpinned image (as for the agent), `cp.endpoint` or an Argo CD `baseURL` that isn't `https://` without `insecureTransport=true` or carries userinfo, a query or a fragment, missing `identity.existingSecret`, no Argo CD connector, an `eso` or `rollout` connector, a connector without `tokenSecret` name and key, duplicate or non-DNS-label connector names, NetworkPolicy on without egress peers | `gateway` | fails template time |

## Pod rollout on Secret rotation

Both charts default `secrets.reloader.enabled=true` (CP umbrella) and `reloader.enabled=true` (agent), and stamp `secret.reloader.stakater.com/reload: "<secret-name>"` on every Deployment that envFrom's a Secret. Install [stakater/reloader](https://github.com/stakater/Reloader) once per cluster and ESO-driven Secret refreshes propagate to a pod restart within ~30s.

## Versioning

What `chart-publish.yml` pushes to `oci://ghcr.io/secrets-bridge/charts/<chart>`:

| Trigger | Chart version | Default image tag (`appVersion`) |
|---|---|---|
| Push to `main` | `<Chart.yaml version>-dev.<charts commit>`, e.g. `0.0.1-dev.54b682c` | `dev`, from `Chart.yaml` |
| Tag `vX.Y.Z` on this repo | `X.Y.Z`, which must equal `Chart.yaml`'s version | `X.Y.Z` |

Before it pushes a chart, the job renders it and checks that every image it references by default exists on GHCR, so a chart can't default to a tag that was never pushed. The `-dev.<sha>` in a dev chart version is a commit in this repo, not an image tag.

Each app repo's `docker-publish.yml` pushes `dev`, `main` and `sha-<commit>` on every push to `main`, and `X.Y.Z`, `X.Y`, `X` (from 1.0) and `latest` (non-prerelease only) for a `vX.Y.Z` tag. Of these, only `X.Y.Z` and `sha-<commit>` count as pins; a digest is better still.

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
│
└── gateway/                                  Optional observation plane (Release 1: Argo CD only)
    ├── Chart.yaml                            chart name: secrets-bridge-gateway
    ├── values.yaml
    ├── values.schema.json                    refuses unknown keys, including R2 connector kinds
    ├── README.md
    ├── ci/r1-values.yaml                     CI preset (not packaged)
    └── templates/
        ├── _helpers.tpl                      names, image, connectors file
        ├── _validation.tpl                   render-time safety rails
        ├── configmap-connectors.yaml         connectors file, no tokens
        ├── deployment.yaml                   read-only Secret file mounts, exec probes
        ├── serviceaccount.yaml               no RBAC, token not mounted
        ├── networkpolicy.yaml                no ingress; egress to DNS, CP and Argo CD only
        ├── pdb.yaml
        └── NOTES.txt
```

## Operator references

- **Full operator docs:** [`secrets-bridge/README.md`](./secrets-bridge/README.md) (CP), [`agent/README.md`](./agent/README.md) (agent), [`gateway/README.md`](./gateway/README.md) (Gateway)
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
