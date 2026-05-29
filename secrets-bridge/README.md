# secrets-bridge

Helm chart for the **Secrets Bridge control plane** — `api` (Fiber/Go), `worker` (sweepers + GitOps poller), `ui` (React SPA), and `controller` (Kubernetes reconciler), bundled together with a shared ingress.

The **agent** runs in workload clusters and ships in its own chart (`charts/agent/`, follow-up). This chart is the operator-facing install for the control-plane cluster only.

> Pre-v0.1.0 — both the chart and the images it ships are rolling on the `:dev` tag. First release will bump both to `v0.1.0`.

## TL;DR

```bash
# 1. Pre-create the env Secret (operator owns this — use ESO,
#    sops, or sealed-secrets as fits your shop). See
#    "Required secrets" below for the key list.
kubectl create namespace secrets-bridge
kubectl -n secrets-bridge apply -f my-env-secret.yaml

# 2. Install with vault-transit OR aws-kms — never local in prod.
helm install secrets-bridge ./charts/secrets-bridge \
  --namespace secrets-bridge \
  --set ingress.host=secrets-bridge.example.com \
  --set kms.backend=aws-kms \
  --set kms.awsKms.region=us-east-1 \
  --set kms.awsKms.keyId=alias/sb-wrap \
  --set api.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::123456789012:role/secrets-bridge-api
```

## What this chart does

| Component | Renders | Why |
|---|---|---|
| `api` | Deployment + Service + ServiceAccount + PDB + HPA (opt) | Fiber/Go control-plane API |
| `ui` | Deployment + Service + ServiceAccount + PDB | React SPA served by nginx |
| `ingress` | Single Ingress with path routing | Same host → ui at `/`, api at `/api/v1`, `/healthz`, `/readyz`, `/metrics` |
| `worker` | _follow-up PR_ | Sweepers + GitOps poller |
| `controller` | _follow-up PR_ | Kubernetes CRD reconciler |

The shared ingress is the key piece — the SPA's `/api/v1/*` calls go to the same host as the SPA itself, no CORS, one TLS cert. Path priority is rendered with `/api`, `/healthz`, `/readyz`, `/metrics` first so they win over the `/` ui catch-all.

## Required secrets

The chart consumes a pre-existing Kubernetes Secret named by `secrets.existingSecret` (default `secrets-bridge-env`). The keys it expects depend on `kms.backend`:

| Key | Always | `vault-transit` | `aws-kms` | `local` (dev) |
|---|---|---|---|---|
| `DATABASE_URL` | ✓ | ✓ | ✓ | ✓ |
| `REDIS_URL` | ✓ | ✓ | ✓ | ✓ |
| `SB_JWT_SECRET` | ✓ | ✓ | ✓ | ✓ |
| `SB_DEV_SEED_PASSWORD` | _(optional dev)_ | — | — | optional |
| `SB_WRAP_MASTER_KEY` | _(local only)_ | — | — | ✓ |
| `SB_KMS_VAULT_ADDR` | — | ✓ | — | — |
| `SB_KMS_VAULT_TOKEN` | — | ✓ | — | — |
| `SB_KMS_VAULT_KEY` | — | ✓ | — | — |
| `SB_KMS_AWS_REGION` | — | — | ✓ | — |
| `SB_KMS_AWS_KEY_ID` | — | — | ✓ | — |

For `aws-kms`, the api **also** needs IRSA — annotate the api ServiceAccount with the IAM role ARN that holds `kms:Encrypt` / `kms:Decrypt` / `kms:GenerateDataKey` on the configured CMK. See `api.serviceAccount.annotations`.

## Safety rails (rendered before any pod boots)

| Guard | Behaviour |
|---|---|
| `kms.backend=local` + `env=production` | `helm install` **errors out** at template time. The api binary would also refuse to boot — the chart catches it first. |
| `env` not in `{dev, production}` | Errors out at template time. |
| `kms.backend` not in `{local, vault-transit, aws-kms}` | Errors out at template time. |
| `vault-transit` selected without `kms.vaultTransit.key` AND no `secrets.existingSecret` | Errors out. |
| `aws-kms` selected without `kms.awsKms.region` / `keyId` AND no `secrets.existingSecret` | Errors out. |

## Pod rollout on Secret rotation

When `secrets.reloader.enabled=true` (default), the chart annotates the api Deployment with `secret.reloader.stakater.com/reload: "<secrets.existingSecret>"`. [stakater/reloader](https://github.com/stakater/Reloader) — install once per cluster — watches the Secret and rolls the pods within ~30s of a content change. This is how ESO-driven Secret refreshes propagate into the api.

## Same-origin ingress posture

```
            ┌─────────────────────────────────────────┐
            │ https://secrets-bridge.example.com      │
            │                                         │
            │  /api/v1/*  ──┐                         │
            │  /healthz   ──┼──→  api Service :8080   │
            │  /readyz    ──┘                         │
            │  /metrics   ──┘                         │
            │                                         │
            │  / (everything else) ──→  ui Service    │
            └─────────────────────────────────────────┘
```

The SPA loads from `/`, makes XHR calls to `/api/v1/*` on the same origin, gets back a JWT, stores it in memory. No CORS, no second domain, one TLS cert.

To shift the api root path (e.g. proxy already prepends `/sb/api/v1`), override `ingress.apiPaths`:

```yaml
ingress:
  apiPaths:
    - /sb/api
    - /sb/healthz
    - /sb/readyz
```

## Configuration reference

`values.yaml` is the authoritative reference. Highlights:

| Key | Default | Notes |
|---|---|---|
| `env` | `production` | `dev` or `production`. Threaded as `SB_ENV`. |
| `kms.backend` | `vault-transit` | `vault-transit`, `aws-kms`, `local`. |
| `secrets.existingSecret` | `secrets-bridge-env` | Pre-created K8s Secret. |
| `secrets.reloader.enabled` | `true` | Annotate Deployments for stakater/reloader. |
| `api.replicaCount` | `2` | |
| `api.autoscaling.enabled` | `false` | HPA opt-in. |
| `api.serviceAccount.annotations` | `{}` | IRSA role ARN goes here. |
| `ui.replicaCount` | `2` | |
| `ingress.enabled` | `true` | |
| `ingress.host` | `secrets-bridge.example.com` | |
| `ingress.tls.clusterIssuer` | `""` | When set, adds `cert-manager.io/cluster-issuer` annotation. |
| `worker.enabled` | `false` | Lands in a follow-up PR. |
| `controller.enabled` | `false` | Lands in a follow-up PR. |

## Roadmap

| Item | Status |
|---|---|
| api Deployment + Service + SA + PDB + HPA | ✓ this PR |
| ui Deployment + Service + SA + PDB | ✓ this PR |
| Shared Ingress with path routing | ✓ this PR |
| KMS safety rails | ✓ this PR |
| Reloader integration | ✓ this PR |
| worker Deployment + ScaledObject | follow-up |
| controller Deployment + CRDs + RBAC | follow-up |
| NetworkPolicy templates | follow-up |
| ServiceMonitor (Prometheus) | follow-up |
| `charts/agent/` (workload-cluster install) | separate chart |

## License

Apache-2.0
