# secure-mcp on Kubernetes

K8s deployment for the secure-mcp demo. Mirrors the local-dev architecture
(3 per-op MCP servers + a UI backend + Postgres + Keycloak) but wires
them up as cluster workloads instead of `docker-compose` + `diagrid dev run`.

This is a **demo deployment** — no auth on the UI backend, no production
secret hygiene, single-replica everything. Don't ship to prod as-is.

## Architecture

One Azure LoadBalancer fronts an nginx-ingress controller. The whole stack
sits on ClusterIP Services behind that single LB; nginx routes by path:

```
                            ┌────────────────────────────────┐
                            │  Catalyst Cloud (Diagrid SaaS) │
                            │  policy / ACL / JWT middleware │
                            └────────────────┬───────────────┘
                                             │ Catalyst's egress IPs
                                             ▼  (allowlisted on LB)
┌────────────────────────────────────────────────────────────────┐
│                       Kubernetes cluster                       │
│                                                                │
│   ┌──────────────────────────────────────────────────────┐     │
│   │  Azure LoadBalancer  ◄── service.beta.../azure-dns-  │     │
│   │  → ingress-nginx     ◄──   label-name + sourceRanges │     │
│   └──────────────────────┬───────────────────────────────┘     │
│                          │                                     │
│        path-based routing on one FQDN                          │
│   /         → ui-backend          (UI + /api/*)                │
│   /keycloak → keycloak    (KC_HTTP_RELATIVE_PATH=/keycloak)    │
│   /mcp/query  → mcp-db-query    (rewrite → /mcp)               │
│   /mcp/write  → mcp-db-write    (rewrite → /mcp)               │
│   /mcp/delete → mcp-db-delete   (rewrite → /mcp)               │
│                                                                │
│   ┌─────────────┐  ┌─────────────┐                             │
│   │ postgresql  │  │  keycloak   │  ← bitnami subcharts        │
│   │ (bitnami)   │  │ (bitnami)   │    (ClusterIP)              │
│   └─────────────┘  └─────────────┘                             │
└────────────────────────────────────────────────────────────────┘
```

Key benefits of the one-LB approach:
- One Azure LB to pay for / monitor (not five)
- One DNS label and one place to keep the Diagrid egress allowlist
- One spot to add TLS later (cert-manager + Let's Encrypt) when a real
  domain is available

## Layout

```
k8s/
├── README.md                       (this file)
├── CATALYST.md                     (Catalyst Cloud connection model)
├── Makefile                        (install-ingress, install, register-appids…)
├── docker/
│   ├── postgresql-mcp.Dockerfile   single image, used for all 3 MCP servers
│   └── ui-backend.Dockerfile       UI backend + bundled prototype
└── helm/
    └── secure-mcp/
        ├── Chart.yaml              chart + bitnami subchart deps
        ├── values.yaml             defaults
        ├── files/                  symlinks to schema.sql + realm-export.json
        └── templates/
            ├── ingress.yaml        two Ingress resources (rewrite + passthrough)
            ├── mcp-servers.yaml    3 Deployment+Service pairs (one per op)
            ├── ui-backend.yaml     Deployment + Service
            ├── postgres-init-cm.yaml
            ├── keycloak-realm-cm.yaml
            └── secrets.yaml
```

## Known tech debt

- **UI backend image bundles the `diagrid` CLI** rather than calling the
  Diagrid REST API directly. Convenient (the local-dev codepath ports
  unchanged) but pulls a CLI binary into the image and requires
  `DIAGRID_API_KEY` to be available to the pod. Future cleanup: swap
  `subprocess.run` calls in `ui_backend/main.py` for `httpx` against
  `https://api.diagrid.io/...`.
- **HTTP-only** ingress. Let's Encrypt won't issue certs for
  `*.cloudapp.azure.com`. When a real domain is available, add
  cert-manager + a ClusterIssuer, then flip the Ingress to TLS.

## Quick start

```bash
cd k8s/

# 1. Build + push images
REGISTRY=ghcr.io/yourorg IMAGE_TAG=dev make build-images push-images

# 2. Install ingress-nginx (once per cluster). The Azure DNS label becomes
#    the shared FQDN; CATALYST_EGRESS_CIDRS locks the LB to Catalyst's
#    egress range so /mcp/* paths can only be reached by Catalyst Cloud.
INGRESS_DNS_LABEL=securemcp \
AZURE_REGION=eastus \
CATALYST_EGRESS_CIDRS="20.x.x.x/32,20.x.x.y/32" \
make install-ingress

# 3. Wait for the Azure LB to provision (~1-2 min)
kubectl -n ingress-nginx get svc ingress-nginx-controller --watch

# 4. Install the secure-mcp chart
REGISTRY=ghcr.io/yourorg \
DIAGRID_API_KEY=$YOUR_KEY \
INGRESS_DNS_LABEL=securemcp \
AZURE_REGION=eastus \
make install

# make install also runs make agent-tokens when DIAGRID_API_KEY is set.
# That caches analyst/ops/admin Catalyst tokens in the catalyst-mcp-client-tokens
# Secret so the UI backend does not need to shell out for every invoke.

# 5. Register the per-op URLs with Catalyst
make register-appids

# 6. Verify reachability
curl -s "http://securemcp.eastus.cloudapp.azure.com/keycloak/realms/secure-mcp/.well-known/openid-configuration" | jq .issuer
# expect: http://securemcp.eastus.cloudapp.azure.com/keycloak/realms/secure-mcp

# 7. Open the UI
open http://securemcp.eastus.cloudapp.azure.com/
```

### Keycloak realm import

The chart imports `keycloak/realm-export.json` through Bitnami's
`keycloakConfigCli` Job, not through Keycloak's boot-time
`--import-realm` directory. This is deliberate: the Bitnami container owns
`/opt/bitnami/keycloak/data` with an internal writable mount, and adding a
second realm-file mount under that tree can make Keycloak start cleanly while
importing an empty directory.

After `make install`, verify the Job and realm:

```bash
kubectl -n secure-mcp get job secure-mcp-keycloak-keycloak-config-cli
kubectl -n secure-mcp logs job/secure-mcp-keycloak-keycloak-config-cli
curl -s "http://securemcp.eastus.cloudapp.azure.com/keycloak/realms/secure-mcp/.well-known/openid-configuration" | jq .issuer
```

If the curl returns `{"error":"Realm does not exist"}`, the Keycloak pod is
up but the config-cli import did not apply. Check the importer first:

```bash
kubectl -n secure-mcp get pods,jobs | grep keycloak-config
kubectl -n secure-mcp logs job/secure-mcp-keycloak-keycloak-config-cli --tail=200
kubectl -n secure-mcp get pod secure-mcp-keycloak-0
```

Common causes:

- Keycloak was not reachable yet when the hook ran.
- Postgres was restarting or had stale PVC state.
- A previous failed hook Job is still present.

Recovery:

```bash
kubectl -n secure-mcp delete job secure-mcp-keycloak-keycloak-config-cli --ignore-not-found

DIAGRID_API_KEY=$YOUR_KEY \
INGRESS_DNS_LABEL=securemcp \
AZURE_REGION=eastus \
HELM_TIMEOUT=15m \
make install

curl -s "http://securemcp.eastus.cloudapp.azure.com/keycloak/realms/secure-mcp/.well-known/openid-configuration" | jq .issuer
```

Expected issuer:

```text
http://securemcp.eastus.cloudapp.azure.com/keycloak/realms/secure-mcp
```

If Keycloak is crash-looping, inspect Keycloak and Postgres before rerunning
the hook:

```bash
kubectl -n secure-mcp logs secure-mcp-keycloak-0 --tail=120
kubectl -n secure-mcp logs secure-mcp-postgresql-0 --tail=120
```

For a disposable demo cluster, the fastest recovery from incompatible or stale
Postgres data is a clean namespace reinstall:

```bash
make uninstall
make install
```

### Diagrid agent token cache

The UI backend can invoke Diagrid as analyst, ops, or admin. It reads those
App ID tokens from an optional Secret named `catalyst-mcp-client-tokens`:

```text
analyst
ops
admin
present
```

`make install` creates or refreshes this Secret automatically when
`DIAGRID_API_KEY` is set. You can refresh it independently after rotating or
recreating App IDs:

```bash
DIAGRID_API_KEY=$YOUR_KEY make agent-tokens
kubectl -n secure-mcp get secret catalyst-mcp-client-tokens
kubectl -n secure-mcp rollout restart deploy/secure-mcp-ui
```

The Secret refs in the UI Deployment are optional. If the Secret is absent,
the UI backend falls back to `diagrid appid get` at runtime, which works but is
slower and noisier during demos.

### Variables `make` honors

| Variable                | Default              | Purpose |
|-------------------------|----------------------|---------|
| `REGISTRY`              | `ghcr.io/yourorg`    | Where to push/pull images |
| `IMAGE_TAG`             | `dev`                | Image tag |
| `NAMESPACE`             | `secure-mcp`         | Install namespace for the chart |
| `RELEASE`               | `secure-mcp`         | Helm release name |
| `INGRESS_DNS_LABEL`     | `securemcp`          | Azure DNS label (must be unique within region) |
| `AZURE_REGION`          | `eastus`             | Azure region for the FQDN |
| `DIAGRID_PROJECT`       | `secure-mcp-demo`    | Diagrid project name |
| `DIAGRID_API_KEY`       | _(unset)_            | If set, creates `catalyst-api-key` Secret |
| `CATALYST_EGRESS_CIDRS` | _(unset)_            | Comma-separated CIDRs → LB `loadBalancerSourceRanges` |

Run `make help` for the live list.

### Why an Ingress at all (vs. multiple LoadBalancer Services)

Earlier iterations of this chart used one Azure LoadBalancer per Service
(query, write, delete, keycloak, ui = 5 LBs). Switching to ingress-nginx
collapses them to one LB. Trade-off: nginx-ingress is a one-time install,
and we use path-based routing (because we don't have a real domain yet)
instead of hostname-based. Future: when a domain is in place, swap to
hostname routing + cert-manager TLS.

## Diagrid integration

See [CATALYST.md](./CATALYST.md). TL;DR: each MCP server's app-endpoint
URL is `http://<ingress-fqdn>/mcp/<op>`. `make register-appids` runs the
`diagrid appid update --app-endpoint …` calls.
