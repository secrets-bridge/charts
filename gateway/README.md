# secrets-bridge-gateway

Helm chart for the Secrets Bridge Gateway, Release 1. The Gateway runs inside a customer boundary, claims observation tasks from the control plane over outbound HTTPS, reads the state of the Argo CD Applications it is configured for, and reports metadata-only evidence. Design: [gateway ADR 0001](https://github.com/secrets-bridge/gateway/blob/main/docs/adr/0001-gateway-observation-plane.md) and [runtime design section 11](https://github.com/secrets-bridge/gateway/blob/main/docs/design/runtime.md#11-helm-chart).

Release 1 is Argo CD rollout-state observation only. Argo CD `Healthy` and `Synced` are observed operational state, not proof that a new secret value reached a running workload.

## What the chart renders

| Kind | Notes |
|---|---|
| Deployment | `replicaCount` replicas (default 2) sharing one Gateway identity. No ports, no Service |
| ConfigMap | The connectors file (`SB_GATEWAY_CONNECTORS_FILE`): Argo CD URLs, project and application allowlists, file paths. No token |
| ServiceAccount | No Role or binding, `automountServiceAccountToken: false` |
| NetworkPolicy | On by default. No ingress; egress to DNS, the control plane and each Argo CD endpoint only |
| PodDisruptionBudget | `minAvailable: 1` when `replicaCount` is 2 or more |

It renders no Secret, no Role, ClusterRole or binding, no Service, Ingress or PVC.

## Hard rules

- **Argo CD only.** `connectors.argocd` is the only connector list. The Release 2 kinds (`eso`, `rollout`) are not supported by this chart: `values.schema.json` refuses `connectors.eso` and `connectors.rollout`, and the chart never sets `SB_GATEWAY_ENABLE_R2_CONNECTORS`.
- **No Kubernetes access.** The Gateway reads no Kubernetes API in Release 1, so there is no RBAC and the ServiceAccount token is not mounted, on the ServiceAccount and on the pod. There is no value to turn it on.
- **Credentials as read-only files.** The identity and every Argo CD token come from existing Secrets, mounted read-only with mode 0440 and `fsGroup`. They never appear in values, env vars or the ConfigMap. Token Secrets are directory mounts, so a rotated token reaches the pod without a restart.
- **Loopback only.** `/healthz`, `/readyz` and `/metrics` listen on `127.0.0.1:<localPort>`. Probes are exec probes on `gateway healthcheck` (readiness) and `gateway healthcheck --live` (liveness), which work in the distroless image ([gateway#19](https://github.com/secrets-bridge/gateway/pull/19)). Metrics are not exposed outside the pod in this release.
- **Hardened pod.** Non-root (65532), read-only root filesystem, all capabilities dropped, `seccompProfile: RuntimeDefault`, no privilege escalation.
- **Pinned image.** A digest, `X.Y.Z` or `sha-<hex>` tag, unless `image.allowMutableTag=true` (dev only).

## Install

### 1. Enrollment

The pod never enrolls. You enroll once, outside the cluster, and store the result in a Secret.

1. An admin with `gateway.mint` creates the Gateway in the console and mints a one-time enrollment token for it (the admin routes are in the api since [api#295](https://github.com/secrets-bridge/api/pull/295); until the console page lands in [ui#163](https://github.com/secrets-bridge/ui/issues/163), use the steps in the [Gateway operations guide](https://secrets-bridge.io/latest/operations/gateway/)).
2. Exchange the token for the credential. The Gateway binary has no `enroll` subcommand yet, so call the enrollment endpoint (`POST /api/v1/gateways/enroll`) directly. The response carries the secret once. This pipeline keeps the token and the secret off the command line (`printf` is a shell builtin, so the token never appears in a process list), out of shell history and off disk, and writes only `gateway_id` and `gateway_secret` into the Secret:

```bash
CP=https://cp.example.com
kubectl create namespace tenant-a-uat
read -rs SB_GATEWAY_ENROLL_TOKEN
printf '%s' "$SB_GATEWAY_ENROLL_TOKEN" | jq -Rc '{enrollment_token: ., cluster_name: "tenant-a-uat"}' \
  | curl -fsS -X POST "$CP/api/v1/gateways/enroll" \
      -H 'Content-Type: application/json' --data-binary @- \
  | jq -ce '{gateway_id, gateway_secret}' \
  | kubectl -n tenant-a-uat create secret generic sb-gateway-identity \
      --from-file=identity.json=/dev/stdin
unset SB_GATEWAY_ENROLL_TOKEN
```

`cluster_name` is optional and only checked when the token was minted with an expected cluster name. The token is single use: if any step of the pipeline fails after the control plane answered, the credential is lost, and the admin revokes the Gateway and creates a new one.

If your Secrets come from a vault through External Secrets Operator, store the same JSON in the vault and render it into a Secret under the key `identity.json` (or set `identity.key`).

### 2. Argo CD account and token

Create a local Argo CD account with API key access and read-only RBAC. `applications, get` is the only permission the Gateway needs.

```yaml
# argocd-cm
data:
  accounts.sb-gateway: apiKey
```

```csv
# argocd-rbac-cm, one line per allowed AppProject
p, role:sb-gateway-read, applications, get, tenant-a-uat/*, allow
g, sb-gateway, role:sb-gateway-read
```

Generate a token and store it in a Secret, again without echoing it:

```bash
argocd account generate-token --account sb-gateway --expires-in 2160h \
  | kubectl -n tenant-a-uat create secret generic sb-gateway-argocd-main \
      --from-file=token=/dev/stdin
```

### 3. Values and install

```yaml
# gateway-values.yaml
image:
  digest: sha256:<gateway-digest>
cp:
  endpoint: https://cp.example.com
  egress:
    cidrs: [192.0.2.10/32]          # what cp.example.com resolves to
identity:
  existingSecret: sb-gateway-identity
connectors:
  argocd:
    - name: argocd-main
      baseURL: https://argocd.example.com
      tokenSecret:
        name: sb-gateway-argocd-main
        key: token
      allowedProjects: [tenant-a-uat]
      applications:
        - id: payments-api          # the target id the control plane names
          name: payments-api        # the Argo CD Application
      egress:
        cidrs: [198.51.100.20/32]   # what argocd.example.com resolves to
        port: 443
```

```bash
helm install gateway oci://ghcr.io/secrets-bridge/charts/secrets-bridge-gateway \
  --namespace tenant-a-uat -f gateway-values.yaml
```

For an Argo CD in the same cluster, use selectors instead of CIDRs. `argocd-server` pods listen on 8080:

```yaml
      baseURL: https://argocd-server.argocd.svc
      egress:
        namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: argocd
        podSelector:
          matchLabels:
            app.kubernetes.io/name: argocd-server
        port: 8080
```

#### Pin each Application's uid

Set `applications[].uid` to the Application's `metadata.uid` for every target. It is optional, but without it each replica learns the uid on its own first read and keeps it only in memory. If the Application is deleted and recreated under the same name and the pod then restarts or rolls out, the new replica pins the new object without noticing the change. With `uid` set, every replica checks it from its first read, across restarts. A read that returns another uid is answered with an `error` observation, code `target_identity_changed`, and carries nothing from the new object. The uid stays in the connectors ConfigMap inside your cluster; evidence sent to the control plane carries only a digest of it.

Read the uid with a read-only call, for example:

```bash
kubectl get application -n argocd payments-api -o jsonpath='{.metadata.uid}'
```

Use the namespace the Application lives in (`argocd`, or its `appNamespace`). In the Argo CD UI, open the Application's details and read `metadata.uid` from its live manifest. Then add it to the values:

```yaml
      applications:
        - id: payments-api
          name: payments-api
          uid: 6f1c2c1e-0000-4000-8000-0000000000a1   # metadata.uid, lower-case UUID
```

When you recreate an Application on purpose, read the new uid and update the value. Leave `uid` unset or empty to keep the per-process pin.

A replica turns ready once the control plane has accepted its heartbeat and catalog and every Argo CD self-check (`GET /api/v1/session/userinfo`) has passed. A 401 from the control plane leaves the pod running and not ready, with the reason in the log.

## Render-time guards

Each one fails `helm install` with a message that names the value, and each has a case in the `safety-rails` CI job.

| Guard | Fails when |
|---|---|
| Pinned image | the image resolves to a moving tag (`dev`, `latest`, `main`, `X.Y`, `X`) or a chart dev version, unless `image.allowMutableTag=true`; or `image.digest` is not a bare `sha256:<64 hex>` |
| Control plane | `cp.endpoint` is empty, not `https://` (plain `http://` needs `insecureTransport=true`), or carries userinfo, a query or a fragment |
| Identity | `identity.existingSecret` is empty |
| Connectors | `connectors.argocd` is empty; `connectors.eso` or `connectors.rollout` is set |
| Each Argo CD connector | `name` is not a unique DNS label; `baseURL` is not `https://` (unless `insecureTransport=true`) or has userinfo, a query or a fragment; `tokenSecret.name` or `.key` is empty; `allowedProjects` or `applications` is empty; an application id is repeated or not a DNS label; an application `uid` is set and is not a lower-case UUID |
| NetworkPolicy | with `networkPolicy.enabled=true`: `cp.egress.cidrs` is empty, a connector has neither `egress.cidrs` nor a selector, a CIDR is malformed or is a `/0`, or a peer selects every pod (a selector with no `matchLabels` and no `matchExpressions` entries, with no narrower selector beside it). There is no fallback to egress to anywhere |

## Configuration

| Value | Default | Notes |
|---|---|---|
| `image.repository` | `secrets-bridge/gateway` | under `global.imageRegistry` (`ghcr.io`) |
| `image.digest` / `image.tag` | empty | digest preferred; the tag defaults to the chart's `appVersion` |
| `image.allowMutableTag` | `false` | dev only |
| `replicaCount` | `2` | replicas do not coordinate; the control plane leases each task to one |
| `insecureTransport` | `false` | `SB_INSECURE_TRANSPORT`. Allows `http://` to the control plane and to every Argo CD. Dev only |
| `logLevel` | `info` | `SB_LOG_LEVEL` |
| `shutdownGrace` | empty (15s) | `SB_GATEWAY_SHUTDOWN_GRACE`; keep `terminationGracePeriodSeconds` (30) above it |
| `localPort` | `8091` | loopback port for health and metrics |
| `cp.endpoint` | required | `SB_CP_ENDPOINT` |
| `cp.caExistingSecret` / `cp.caExistingSecretKey` | empty / `ca.crt` | private CA for the control plane (`SB_CP_CA_FILE`) |
| `cp.tlsServerName` | empty | `SB_CP_TLS_SERVER_NAME` |
| `cp.heartbeatInterval`, `cp.claimInterval`, `cp.claimIdleMax`, `cp.claimConcurrency`, `cp.leaseMargin`, `cp.passTimeout`, `cp.unreachableAfter` | empty | loop tuning, the binary defaults apply when empty |
| `cp.egress.cidrs` / `cp.egress.port` | `[]` / `443` | NetworkPolicy peer for the control plane |
| `identity.existingSecret` | required | Secret with the identity JSON |
| `identity.key` | `identity.json` | key in that Secret |
| `connectors.argocd[]` | `[]` | `name`, `baseURL`, `tokenSecret{name,key}`, optional `caSecret{name,key}`, `tlsServerName`, `timeout` (1s to 60s), `allowedProjects`, `applications[]{id,name,appNamespace,uid}` (`uid` optional, see [Pin each Application's uid](#pin-each-applications-uid)), `egress{cidrs,namespaceSelector,podSelector,port}` |
| `networkPolicy.enabled` | `true` | |
| `networkPolicy.dns.namespaceSelector` / `podSelector` | kube-system / `k8s-app: kube-dns` | where DNS traffic may go |
| `serviceAccount.create` / `name` / `annotations` | `true` / empty / `{}` | the token is never mounted either way |
| `podSecurityContext`, `containerSecurityContext` | hardened | see `values.yaml` |
| `livenessProbe`, `readinessProbe` | timing only | the exec command is fixed by the chart |
| `podDisruptionBudget.enabled` / `minAvailable` | `true` / `1` | |
| `resources`, `nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints`, `podAnnotations`, `podLabels` | | standard |

## License

Apache-2.0
