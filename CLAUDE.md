# CLAUDE.md: secrets-bridge/charts

Instructions for Claude Code and contributors working in this repo. For the whole platform, see https://secrets-bridge.io.

## What this repo is

Helm charts for deploying Secrets Bridge.

| Chart | Deploys |
|---|---|
| `secrets-bridge/` | The control plane: api, ui, worker and controller behind one ingress (SPA at `/`, API at `/api/v1`). Reads its configuration from an existing Secret (`secrets.existingSecret`) |
| `agent/` | One agent per workload cluster or account |
| `gateway/` | The optional Gateway, Release 1: read-only Argo CD rollout-state observation. No RBAC, no ServiceAccount token, Argo CD connectors only |

## Build and test

CI runs the same steps:

```bash
helm lint secrets-bridge/
helm lint agent/
helm lint gateway/

# render the presets and validate them
helm template ci-dev secrets-bridge/ <dev preset values> | kubeconform -strict -summary -skip CustomResourceDefinition
helm template ci-agent agent/ <agent preset values> | kubeconform -strict -summary -skip CustomResourceDefinition
helm template ci-gateway gateway/ -f gateway/ci/r1-values.yaml | kubeconform -strict -summary
```

The `safety-rails` CI job checks that bad combinations fail at render time, and for the expected reason: `env=production` with `kms.backend=local`, unknown or wrongly cased `env` / `kms.backend` values, production with an unpinned image tag (`dev`, `latest`, `main`, `X.Y`, `X`, or a chart dev version `X.Y.Z-dev.<sha>`) or a malformed digest, an agent with an unpinned image and no `image.allowMutableTag`, Vault Kubernetes auth with the SA token switched off, an agent without `clusterName`, an agent pointed at plain HTTP without `insecureTransport`, and, with `objectStore.enabled`, an empty bucket or region, `sse=aws:kms` without `kmsKeyId`, `kmsKeyId` with any other `sse`, an unknown `sse`, a prefix with an empty, `.` or `..` segment, a `logoBackfill` that isn't `true` or `false`, a malformed endpoint, a plain `http://` endpoint under `env=production`, and static object store keys with `kms.backend=aws-kms`. For the gateway it checks an unpinned image, an `http://` or userinfo `cp.endpoint` or Argo CD `baseURL` (and a query or fragment on `baseURL`), a missing `identity.existingSecret`, no Argo CD connector, an `eso` or `rollout` connector list, a missing `tokenSecret` name or key, duplicate or non-DNS-label connector names, empty project or application lists, an application `uid` that is not a lower-case UUID, NetworkPolicy without egress peers, and egress peers that allow everything (a `/0` CIDR, or a selector with no entries and nothing narrower beside it). It also checks that pinned images (digest, `X.Y.Z`, `sha-<hex>`) still render, that `SB_REQUIRE_MFA_AT_LOGIN` renders only for an explicit `api.config.mfa.requireMFAAtLogin` bool (unset leaves it to the api's per-env default and the env Secret), and that any other value fails the render. It also checks that the retired GitOps settings (`SB_GITOPS_ENABLED`, `SB_WORKER_GITOPS_*`) never render, that the worker gets no `SB_KMS_*` env, and that the worker's Gateway sweeper env renders only when `worker.config.gatewaySweepers.enabled` is on. Add a case there whenever you add a guard.

`chart-publish.yml` keeps `appVersion` from `Chart.yaml` (`dev`) for charts built from `main` and sets it to `X.Y.Z` for a `vX.Y.Z` tag. Before `helm push` it runs `.github/scripts/check-image-refs.sh`, which fails the job if any image the packaged chart renders by default is missing from GHCR.

## Rules for this repo

- Keep the render-time guards. A misconfiguration should fail `helm install`, not crash a pod later.
- Production installs pin images by `digest`, not by tag.
- Keep the secure defaults: non-root pods, read-only root filesystems where possible, NetworkPolicy, minimal and namespaced RBAC.
- Never put real credentials, account IDs or hostnames in `values.yaml` or examples. Use `example.com` hosts and `123456789012` account IDs.
- The agent chart has no database or Redis settings, by design.
- The gateway chart renders no RBAC and never mounts the ServiceAccount token in Release 1, and it has no switch for the Release 2 connector kinds.
- When a chart change goes with an app change (new env var, new permission), link the PRs and release them together.

## Contributing

Feature branch off `main`, conventional commits, small PRs, CI green, then open a PR for maintainer review. Never push to `main`.

This repo is public. Keep account IDs, hostnames, cluster names, real secret paths and company names out of values, examples, commits, PRs and issues.

**No AI attribution.** Commits and PRs describe the change, nothing else. Don't add `Co-Authored-By` trailers for AI assistants, "Generated with ..." lines or links to AI sessions to commit messages, PR titles or PR bodies. A squash merge copies the PR body into the commit on `main`, where it can't be edited later. If you use a coding assistant, turn off its commit and PR attribution in its settings.
