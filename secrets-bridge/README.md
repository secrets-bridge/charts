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
| `ingress` | Single Ingress with path routing | Same host → ui at `/`, api at `/api/v1` |
| `worker` | Deployment + ServiceAccount + PDB (opt) + NetworkPolicy (opt) | Sweepers + GitOps poller |
| `controller` | Deployment + CRD + RBAC + NetworkPolicy (opt) | Kubernetes CRD reconciler |

The shared ingress is the key piece: the SPA's `/api/v1/*` calls go to the same host as the SPA itself, no CORS, one TLS cert. `/healthz`, `/readyz`, and `/metrics` are deliberately **not** on the public ingress by default (see "Metrics & health checks" below); `apiPaths` defaults to just `/api`.

## Required secrets

The chart consumes a pre-existing Kubernetes Secret named by `secrets.existingSecret` (default `secrets-bridge-env`). The keys it expects depend on `kms.backend`:

| Key | Always | `vault-transit` | `aws-kms` | `local` (dev) |
|---|---|---|---|---|
| `DATABASE_URL` | ✓ | ✓ | ✓ | ✓ |
| `REDIS_URL` | ✓ | ✓ | ✓ | ✓ |
| `SB_JWT_SECRET` | ✓ | ✓ | ✓ | ✓ |
| `SB_BOOTSTRAP_ADMIN_EMAIL` + `SB_BOOTSTRAP_ADMIN_PASSWORD` | optional | optional | optional | optional |
| `SB_OIDC_CLIENT_SECRET` | _(when OIDC enabled)_ | ✓ | ✓ | ✓ |
| `SB_DEV_SEED_PASSWORD` | _(optional dev)_ | — | — | optional |
| `SB_WRAP_MASTER_KEY` | _(local only)_ | — | — | ✓ |
| `SB_KMS_VAULT_ADDR` | — | ✓ | — | — |
| `SB_KMS_VAULT_TOKEN` | — | ✓ | — | — |
| `SB_KMS_VAULT_KEY` | — | ✓ | — | — |
| `SB_KMS_AWS_REGION` | — | — | ✓ | — |
| `SB_KMS_AWS_KEY_ID` | — | — | ✓ | — |
| `SB_WORKER_WEBHOOK_URL` | _(optional)_ | optional | optional | optional |

`SB_WORKER_WEBHOOK_URL` (sweeper-failure notifications) is deliberately **not** a chart value (CHT-05 / M12). Add the key to this same Secret and point `worker.notifications.webhookUrlSecretRef.key` at it; the chart wires a `secretKeyRef`, never a plaintext env value.

For `aws-kms`, the api **also** needs IRSA — annotate the api ServiceAccount with the IAM role ARN that holds `kms:Encrypt` / `kms:Decrypt` / `kms:GenerateDataKey` on the configured CMK. See `api.serviceAccount.annotations`.

## OIDC + auth (Slices A1 → E)

When `api.config.oidc.issuer` is set, the chart wires the OIDC client routes (`/auth/oidc/{start,callback,logout,backchannel}`) into the api deployment. When it's left empty, only the local-admin `/auth/login` path is mounted — A1+A2 deployments work unchanged.

```yaml
api:
  config:
    # Optional first-boot grant of the seed `admin` role. Email +
    # password are confidential and live in the env Secret.
    bootstrap:
      userId: ""

    oidc:
      issuer:             "https://authentik.example.com/application/o/secrets-bridge/"
      clientId:           "secrets-bridge"
      redirectUrl:        "https://secrets-bridge.example.com/api/v1/auth/oidc/callback"
      scopes:             "openid profile email"
      postLogoutRedirect: "https://secrets-bridge.example.com/"

      # Group-claim → role mapping (Slice E). The chart serializes
      # this map to JSON for SB_OIDC_GROUP_MAP at render time.
      groupClaim: groups
      groupMap:
        sb-admins:    admin
        sb-approvers: approver
        sb-devs:      developer
```

**Critical invariant the api enforces — do NOT change this in the chart layer.** The reconciler ONLY touches `user_roles` rows with `granted_by = 'system:oidc'`. Admin-assigned grants (the `SB_BOOTSTRAP_ADMIN_USER_ID` grant, manually-curated team-scoped grants) are **invisible** to the reconciler and survive every reconcile pass — including the "user belongs to no mapped groups" case. The chart's job is to render the env vars; the api owns the security boundary.

**`SB_OIDC_CLIENT_SECRET` lives in the env Secret**, not in values.yaml. The chart never renders it. Use ESO / sealed-secrets / sops to put it into the bag named by `secrets.existingSecret`.

**Cookie attributes are not configurable.** The api hard-codes HttpOnly, SameSite=Strict, Secure (in production), MaxAge = AbsoluteTTL (8h). `env=dev` drops the Secure flag so local Vite dev works at http://localhost. Don't add knobs that let an operator weaken these from values — the security model assumes them.

## Safety rails (rendered before any pod boots)

| Guard | Behaviour |
|---|---|
| `kms.backend=local` + `env=production` | `helm install` **errors out** at template time. The api binary would also refuse to boot — the chart catches it first. |
| `env` not in `{dev, production}` | Errors out at template time. |
| `kms.backend` not in `{local, vault-transit, aws-kms}` | Errors out at template time. |
| `vault-transit` selected without `kms.vaultTransit.key` AND no `secrets.existingSecret` | Errors out. |
| `aws-kms` selected without `kms.awsKms.region` / `keyId` AND no `secrets.existingSecret` | Errors out. |
| `env=production` AND an enabled component resolves to a mutable `:dev` / `:latest` tag with no `image.digest` set | Errors out (CHT-03 / M11); see "Image pinning" below. |

## Image pinning

Pre-v0.1.0, every component's `image.tag` defaults to `.Chart.AppVersion`, which is the literal string `"dev"`: whatever `main` last pushed. `pullPolicy` defaults to `Always` so a mutable tag at least never runs stale once a node has it cached, but under `env=production` the chart goes further and **refuses to render** unless you either:

- set `<component>.image.tag` to a pinned release version, or
- (preferred) set `<component>.image.digest` to an exact `sha256:...` manifest pin, which bypasses the tag entirely and is immune to the tag being repointed later.

```yaml
api:
  image:
    digest: "sha256:<64-hex-digest>"   # preferred: exact, immutable
# or
  image:
    tag: "0.1.0"                       # once a real release exists
```

## Pod rollout on Secret rotation

When `secrets.reloader.enabled=true` (default), the chart annotates the api Deployment with `secret.reloader.stakater.com/reload: "<secrets.existingSecret>"`. [stakater/reloader](https://github.com/stakater/Reloader) — install once per cluster — watches the Secret and rolls the pods within ~30s of a content change. This is how ESO-driven Secret refreshes propagate into the api.

## Same-origin ingress posture

```
            ┌─────────────────────────────────────────┐
            │ https://secrets-bridge.example.com      │
            │                                         │
            │  /api/v1/*  ──────→  api Service :8080  │
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
```

## Metrics & health checks

`/healthz`, `/readyz`, and `/metrics` are intentionally kept off the public ingress (`ingress.apiPaths` defaults to `[/api]` only; see CHT-02 / charts#21). Reach them from inside the cluster instead:

- **Metrics**: point a Prometheus `ServiceMonitor` at the api's ClusterIP Service (`app.kubernetes.io/component: api`), port `http`, path `/metrics`. The default `api.networkPolicy` (see below) only opens `:8080` to the ingress controller's namespace, so add an `extraRules` entry (or a namespace label your Prometheus operator already matches) if your scrape source lives elsewhere.
- **Health checks**: the Deployment's own `livenessProbe` / `readinessProbe` already hit `/healthz` and `/readyz` from the kubelet, no ingress path needed. If your ingress controller or an external load balancer wants an HTTP-level health check path instead, add `/healthz` back to `ingress.apiPaths`.

## NetworkPolicy

`api`, `ui`, `worker`, and `controller` each render a default-deny `NetworkPolicy` (`<component>.networkPolicy.enabled`, default `true` on all four; CHT-01 / charts#21). Requires a NetworkPolicy-enforcing CNI (Calico, Cilium, the AWS VPC CNI network-policy add-on, ...); a non-enforcing CNI silently ignores the object.

| Component | Ingress | Egress |
|---|---|---|
| `api` | `:8080` from `api.networkPolicy.ingress.namespaceSelector` (default `ingress-nginx`) | DNS + `api.networkPolicy.egress.extraRules` (Postgres, Redis, KMS, OIDC: operator-specific, empty by default) |
| `ui` | `:8080` from `ui.networkPolicy.ingress.namespaceSelector` | DNS only (static SPA, no backend calls) |
| `worker` | none (no Service fronts it) | DNS + `worker.networkPolicy.egress.extraRules` |
| `controller` | none, unless `controller.metricsService.enabled` | DNS + broad `443` for the Kubernetes API server (`egress.allowAPIServer`, no portable way to pin its address) |

See each block's comments in `values.yaml` for worked `extraRules` examples (a Postgres+Redis subnet, a Vault endpoint, ...).

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
| `worker.enabled` | `true` | |
| `controller.enabled` | `true` | |
| `api.networkPolicy.enabled` / `ui.…` / `worker.…` / `controller.…` | `true` | Default-deny NetworkPolicy per component. |
| `api.image.digest` / `ui.…` / `worker.…` / `controller.…` | `""` | Immutable `sha256:...` pin; overrides `image.tag` when set. |

## Roadmap

| Item | Status |
|---|---|
| api Deployment + Service + SA + PDB + HPA | ✓ |
| ui Deployment + Service + SA + PDB | ✓ |
| worker Deployment + SA + PDB | ✓ |
| controller Deployment + CRDs + RBAC | ✓ |
| Shared Ingress with path routing | ✓ |
| KMS safety rails + image-tag safety rail | ✓ |
| Reloader integration | ✓ |
| NetworkPolicy templates (api / ui / worker / controller) | ✓ |
| ServiceMonitor (Prometheus) | operator-provided; see "Metrics & health checks" |
| `charts/agent/` (workload-cluster install) | separate chart |

## License

Apache-2.0
