# CLAUDE.md: secrets-bridge/charts

Instructions for Claude Code and contributors working in this repo. For the whole platform, see https://secrets-bridge.io.

## What this repo is

Helm charts for deploying Secrets Bridge.

| Chart | Deploys |
|---|---|
| `secrets-bridge/` | The control plane: api, ui, worker and controller behind one ingress (SPA at `/`, API at `/api/v1`). Reads its configuration from an existing Secret (`secrets.existingSecret`) |
| `agent/` | One agent per workload cluster or account |

## Build and test

CI runs the same steps:

```bash
helm lint secrets-bridge/
helm lint agent/

# render the presets and validate them
helm template ci-dev secrets-bridge/ <dev preset values> | kubeconform -strict -summary -skip CustomResourceDefinition
helm template ci-agent agent/ <agent preset values> | kubeconform -strict -summary -skip CustomResourceDefinition
```

The `safety-rails` CI job checks that bad combinations fail at render time: `env=production` with `kms.backend=local`, unknown `env` or `kms.backend` values, production with a mutable image tag, an agent without `clusterName`, and an agent pointed at plain HTTP without `insecureTransport`. Add a case there whenever you add a guard.

## Rules for this repo

- Keep the render-time guards. A misconfiguration should fail `helm install`, not crash a pod later.
- Production installs pin images by `digest`, not by tag.
- Keep the secure defaults: non-root pods, read-only root filesystems where possible, NetworkPolicy, minimal and namespaced RBAC.
- Never put real credentials, account IDs or hostnames in `values.yaml` or examples. Use `example.com` hosts and `123456789012` account IDs.
- The agent chart has no database or Redis settings, by design.
- When a chart change goes with an app change (new env var, new permission), link the PRs and release them together.

## Contributing

Feature branch off `main`, conventional commits, small PRs, CI green, then open a PR for maintainer review. Never push to `main`.

This repo is public. Keep account IDs, hostnames, cluster names, real secret paths and company names out of values, examples, commits, PRs and issues.
