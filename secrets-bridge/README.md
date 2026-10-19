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
#    env defaults to production, so every image must be pinned
#    (see "Image pinning" below).
helm install secrets-bridge ./charts/secrets-bridge \
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

Object storage (`objectStore.*`) adds no required keys: on AWS it uses IRSA, and static keys for S3-compatible servers come from their own Secret (see "Object storage for media").

For `aws-kms`, the api **also** needs IRSA — annotate the api ServiceAccount with the IAM role ARN that holds `kms:Encrypt` / `kms:Decrypt` / `kms:GenerateDataKey` on the configured CMK. See `api.serviceAccount.annotations`.

## Object storage for media

The api keeps images and media (project and team logos today, any later upload) in S3-compatible object storage, and Postgres keeps only the metadata. The bucket stays private: the api streams objects back through its own routes, so the existing authorization applies. Secret values never go to object storage. The worker doesn't read media, so only the api gets these settings.

`objectStore.enabled` defaults to `false`, so an existing install keeps rendering until it has a bucket. Without object storage the api still boots, but logo uploads and deletes answer `503 logo storage is not configured`. Logos already stored in Postgres keep being served, and the boot log warns with their count. With object storage configured, the api runs `HeadBucket` at boot and refuses to start if a setting is invalid or the bucket can't be reached within 15 seconds.

When `objectStore.enabled` is on, the chart maps the values to env vars on the api:

| Value | Env var | Notes |
|---|---|---|
| `objectStore.bucket` | `SB_OBJECTSTORE_BUCKET` | Required when enabled. |
| `objectStore.region` | `SB_OBJECTSTORE_REGION` | Required when enabled, e.g. `us-east-1`. |
| `objectStore.endpoint` | `SB_OBJECTSTORE_ENDPOINT` | Empty for AWS S3. A full URL (`https://s3.example.com:9000`) for an S3-compatible server or a VPC endpoint. |
| `objectStore.prefix` | `SB_OBJECTSTORE_PREFIX` | Key prefix, so several installs can share a bucket. Slashes at either end are trimmed; empty, `.` or `..` segments are refused. |
| `objectStore.sse` | `SB_OBJECTSTORE_SSE` | `AES256` (chart default, SSE-S3), `aws:kms` (SSE-KMS), or `""` to send no SSE header and rely on the bucket default. The api's own default, with the variable unset, is no header. |
| `objectStore.kmsKeyId` | `SB_OBJECTSTORE_KMS_KEY_ID` | Required when `sse=aws:kms`, refused with any other `sse`. |
| `objectStore.forcePathStyle` | `SB_OBJECTSTORE_FORCE_PATH_STYLE` | `"true"` or `"false"`, always rendered. `true` for MinIO and most S3-compatible servers. |
| `objectStore.logoBackfill` | `SB_OBJECTSTORE_LOGO_BACKFILL` | `"true"` (default) or `"false"`, always rendered. Moves logos still stored in Postgres to the bucket at api start. See "Upgrading from logos in Postgres". |

Logos are stored at `<prefix>/logos/<kind>/<entity-id>/<sha256>.png`, where `<kind>` is `project` or `team`.

You can also leave `objectStore.enabled=false` and put the `SB_OBJECTSTORE_*` keys in `secrets.existingSecret`. The chart then renders nothing for them and skips its checks.

Credentials never go in values. The api uses the standard AWS SDK chain:

- On AWS S3, use IRSA. Annotate the api ServiceAccount (`api.serviceAccount.annotations`) with a role that has `s3:ListBucket` on `arn:aws:s3:::<bucket>`, `s3:GetObject`, `s3:PutObject` and `s3:DeleteObject` on `arn:aws:s3:::<bucket>/<prefix>/*`, and `kms:GenerateDataKey` / `kms:Decrypt` on `kmsKeyId` for SSE-KMS. Don't put an `s3:prefix` condition on `s3:ListBucket`: the boot check is a `HeadBucket` call, which S3 authorizes with `s3:ListBucket` and which sends no prefix, so the condition would deny it and the api would refuse to boot. With `kms.backend=aws-kms` it's the same role.
- For an S3-compatible server, create a Secret with the access key pair and set `objectStore.credentials.existingSecret`. The chart wires `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from it through `secretKeyRef` (key names in `credentials.accessKeyIdKey` / `credentials.secretAccessKeyKey`). This can't be combined with `kms.backend=aws-kms`, because the SDK prefers those variables over IRSA and the KMS client would sign with them.

```yaml
# AWS S3, credentials from IRSA
api:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/secrets-bridge-api
objectStore:
  enabled: true
  bucket: example-bucket
  region: us-east-1
  prefix: secrets-bridge
  sse: aws:kms
  kmsKeyId: alias/sb-media
```

```yaml
# MinIO, static keys from an existing Secret
objectStore:
  enabled: true
  bucket: example-bucket
  region: us-east-1
  endpoint: https://s3.example.com:9000
  forcePathStyle: true
  sse: ""                # MinIO without a KMS rejects SSE-S3 requests
  credentials:
    existingSecret: sb-objectstore-creds
```

### Upgrading from logos in Postgres

Earlier api versions stored logos in Postgres. The api's migration 0040 adds `object_key` and `byte_length` and makes `png` nullable, and the backfill (`objectStore.logoBackfill`) copies existing logos to the bucket at start. It runs in the background on one replica at a time under a Redis lock, is idempotent, and also picks up rows that old replicas write during the rollout. Boot doesn't wait for it: logos still in Postgres are served until they move.

With more than one api replica, upgrade in two steps:

1. Deploy the new api with object storage configured and `objectStore.logoBackfill: false`. Old replicas keep reading and writing Postgres, and new replicas write new logos to the bucket and serve both kinds. Until the rollout finishes, an old replica serves an empty image for a logo uploaded through a new replica.
2. Once every replica runs the new version, set `objectStore.logoBackfill: true` (the default) and upgrade again; the env change restarts the pods. Check the `logo backfill done` log line, or that `SELECT count(*) FROM project_logos WHERE png IS NOT NULL` and the same query on `team_logos` both return 0.

With a single replica, or when that short window doesn't matter, deploy with the default and skip step 1.

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
| `env` not exactly `dev` or `production` | Errors out at template time. The match is case-sensitive (CHT-N-05), like the api and worker: `Production` would render and then crash-loop, so it's refused here. |
| `kms.backend` not exactly `local`, `vault-transit` or `aws-kms` | Errors out at template time (case-sensitive too). |
| `vault-transit` selected without `kms.vaultTransit.key` AND no `secrets.existingSecret` | Errors out. |
| `aws-kms` selected without `kms.awsKms.region` / `keyId` AND no `secrets.existingSecret` | Errors out. |
| `env=production` AND an enabled component has no `image.digest` and its tag isn't pinned (`X.Y.Z`, `vX.Y.Z`, optional `-prerelease`, or `sha-<hex>`; a chart dev version `X.Y.Z-dev.<sha>` doesn't count) | Errors out (CHT-03 / M11, CHT-N-02); see "Image pinning" below. |
| `<component>.image.digest` set to anything but a bare `sha256:<64 hex>` | Errors out in every `env`. |
| `objectStore.enabled=true` with an empty `objectStore.bucket` | Errors out. |
| `objectStore.enabled=true` with an empty `objectStore.region` | Errors out. |
| `objectStore.sse` not exactly `AES256`, `aws:kms` or empty | Errors out (case-sensitive). |
| `objectStore.sse=aws:kms` with an empty `objectStore.kmsKeyId` | Errors out. |
| `objectStore.kmsKeyId` with any `objectStore.sse` other than `aws:kms` | Errors out (the api would refuse to boot). |
| `objectStore.prefix` with an empty, `.` or `..` segment | Errors out. |
| `objectStore.logoBackfill` not `true` or `false` | Errors out. |
| `objectStore.endpoint` that isn't `http(s)://host[:port]` | Errors out. |
| `objectStore.endpoint` with plain `http://` under `env=production` | Errors out. Plain HTTP is fine under `env=dev` (local MinIO). |
| `objectStore.credentials.existingSecret` with `kms.backend=aws-kms` | Errors out: the static keys would take over the KMS client's credentials. |

The `objectStore` checks only run when `objectStore.enabled=true`.

## Image pinning

Every component's `image.tag` defaults to `.Chart.AppVersion`. In this repo and in every chart published from `main` (versions like `0.0.1-dev.<sha>`), that's the literal string `"dev"`: whatever `main` last pushed. A chart published from a `vX.Y.Z` tag defaults to the `X.Y.Z` images, and the publish job refuses to push it unless every default image has that tag. The image builds also push `main`, `X.Y` and `X` tags, which move like `dev` does. `pullPolicy` defaults to `Always` so a mutable tag at least never runs stale once a node has it cached, but under `env=production` the chart goes further: a tag is only accepted if it's on an allow-list (CHT-N-02), and anything else **refuses to render**. Either:

- (preferred) set `<component>.image.digest` to the bare `sha256:<64 hex>` manifest digest (no repository, no `@`; the chart renders `<repository>@<digest>`), which bypasses the tag entirely and is immune to the tag being repointed later, or
- set `<component>.image.tag` to a full release version (`0.1.0`, `v0.1.0`, `1.2.0-rc.1`) or the `sha-<commit>` tag every image build pushes.

`dev`, `latest`, `main`, `X.Y` (`0.1`) and `X` (`1`) are refused. So is a chart dev version such as `0.0.1-dev.<sha>`: it looks like a semver prerelease, but the `<sha>` is a commit in this repo and no image is tagged with it.

```yaml
api:
  image:
    digest: "sha256:<64-hex-digest>"   # preferred: exact, immutable
# or
  image:
    tag: "sha-1a2b3c4"                 # the build of one main commit
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

The SPA loads from `/`, makes XHR calls to `/api/v1/*` on the same origin, and authenticates with the HttpOnly session cookie that login sets. No CORS, no second domain, one TLS cert.

To shift the api root path (e.g. proxy already prepends `/sb/api/v1`), override `ingress.apiPaths`:

```yaml
ingress:
  apiPaths:
    - /sb/api
```

## Metrics & health checks

`/healthz`, `/readyz`, and `/metrics` are intentionally kept off the public ingress (`ingress.apiPaths` defaults to `[/api]` only; see CHT-02 / charts#21). Reach them from inside the cluster instead:

- **Metrics**: point a Prometheus `ServiceMonitor` at the api's ClusterIP Service (`app.kubernetes.io/component: api`), port `http`, path `/metrics`. The default `api.networkPolicy` (see below) only opens `:8080` to the ingress controller's namespace, so a scrape from anywhere else, the release namespace included, is dropped. `extraRules` only covers egress; NetworkPolicies are additive, so add a separate policy that selects the api pods and admits your Prometheus namespace on TCP 8080.
- **Health checks**: the Deployment's own `livenessProbe` / `readinessProbe` already hit `/healthz` and `/readyz` from the kubelet, no ingress path needed. If your ingress controller or an external load balancer wants an HTTP-level health check path instead, add `/healthz` back to `ingress.apiPaths`.

## NetworkPolicy

`api`, `ui`, `worker`, and `controller` each render a default-deny `NetworkPolicy` (`<component>.networkPolicy.enabled`, default `true` on all four; CHT-01 / charts#21). Requires a NetworkPolicy-enforcing CNI (Calico, Cilium, the AWS VPC CNI network-policy add-on, ...); a non-enforcing CNI silently ignores the object.

| Component | Ingress | Egress |
|---|---|---|
| `api` | `:8080` from `api.networkPolicy.ingress.namespaceSelector` (default `ingress-nginx`) | DNS + the object store when `objectStore.enabled` (see below) + `api.networkPolicy.egress.extraRules` (Postgres, Redis, KMS, OIDC: operator-specific, empty by default) |
| `ui` | `:8080` from `ui.networkPolicy.ingress.namespaceSelector` | DNS only (static SPA, no backend calls) |
| `worker` | none (no Service fronts it) | DNS + `worker.networkPolicy.egress.extraRules` |
| `controller` | none, unless `controller.metricsService.enabled` | DNS + broad `443` for the Kubernetes API server (`egress.allowAPIServer`, no portable way to pin its address) |

See each block's comments in `values.yaml` for worked `extraRules` examples (a Postgres+Redis subnet, a Vault endpoint, ...).

With `objectStore.enabled=true` the api policy also allows TCP egress to the object store (`api.networkPolicy.egress.objectStore.enabled`, default `true`). The port comes from `objectStore.endpoint`: its explicit port, else 443 for `https` or 80 for `http`, and 443 when there's no endpoint (AWS S3). S3's addresses aren't fixed, so by default the rule allows that port to any destination, like the controller's API server rule. Narrow it with `api.networkPolicy.egress.objectStore.to` (NetworkPolicy peers, such as the S3 VPC endpoint subnet or the namespace of an in-cluster MinIO), or set `enabled: false` and write the rule in `extraRules` yourself.

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
| `api.serviceAccount.annotations` | `{}` | IRSA role ARN goes here (KMS and S3). |
| `objectStore.enabled` | `false` | Object storage for media. `bucket` is required when `true`. |
| `objectStore.bucket` / `region` / `endpoint` / `prefix` | `""` | `SB_OBJECTSTORE_*` on the api. `bucket` and `region` are required when enabled. |
| `objectStore.sse` / `kmsKeyId` | `AES256` / `""` | `aws:kms` needs `kmsKeyId`. |
| `objectStore.forcePathStyle` | `false` | `true` for MinIO. |
| `objectStore.logoBackfill` | `true` | Move logos still in Postgres to the bucket at api start. `false` for step 1 of a multi-replica upgrade. |
| `objectStore.credentials.existingSecret` / `accessKeyIdKey` / `secretAccessKeyKey` | `""` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Static keys for S3-compatible servers. Not with `kms.backend=aws-kms`. |
| `api.networkPolicy.egress.objectStore.enabled` / `.to` | `true` / `[]` | Egress to the object store when `objectStore.enabled`. |
| `ui.replicaCount` | `2` | |
| `ingress.enabled` | `true` | |
| `ingress.host` | `secrets-bridge.example.com` | |
| `ingress.tls.clusterIssuer` | `""` | When set, adds `cert-manager.io/cluster-issuer` annotation. |
| `worker.enabled` | `true` | |
| `controller.enabled` | `true` | |
| `api.networkPolicy.enabled` / `ui.…` / `worker.…` / `controller.…` | `true` | Default-deny NetworkPolicy per component. |
| `api.image.digest` / `ui.…` / `worker.…` / `controller.…` | `""` | Bare `sha256:<64 hex>` pin; overrides `image.tag` when set. |
| `api.image.tag` / `ui.…` / `worker.…` / `controller.…` | `""` (→ `dev`) | Under `env=production` must be `X.Y.Z`, `vX.Y.Z` (optional `-prerelease`) or `sha-<hex>`. |
| `api.serviceAccount.automountServiceAccountToken` / `worker.…` | `false` | Rendered on the pod spec too, so it holds with `serviceAccount.create=false`. ui is always `false`. |

## Roadmap

| Item | Status |
|---|---|
| api Deployment + Service + SA + PDB + HPA | ✓ |
| ui Deployment + Service + SA + PDB | ✓ |
| worker Deployment + SA + PDB | ✓ |
| controller Deployment + CRDs + RBAC | ✓ |
| Shared Ingress with path routing | ✓ |
| KMS safety rails + image-tag safety rail | ✓ |
| Object storage settings for media (S3, S3-compatible) | ✓ |
| Reloader integration | ✓ |
| NetworkPolicy templates (api / ui / worker / controller) | ✓ |
| ServiceMonitor (Prometheus) | operator-provided; see "Metrics & health checks" |
| `charts/agent/` (workload-cluster install) | separate chart |

## License

Apache-2.0
