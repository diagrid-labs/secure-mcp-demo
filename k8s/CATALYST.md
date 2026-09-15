# Catalyst integration — Cloud + nginx-ingress

Catalyst Cloud hosts the Dapr runtime centrally. Per
<https://docs.diagrid.io/develop/connect>, your apps don't run any
in-cluster sidecar — they expose an HTTP endpoint and Catalyst forwards
inbound MCP calls to it. This chart uses the **MCPServer resource** model:
a single `postgresql-mcp` app handles all tools, and Catalyst's MCP proxy
routes calls after enforcing the per-tool access policy.

## Trust model

The MCP server is on a `ClusterIP` Service — not directly reachable from
outside. The only public surface is the **nginx-ingress controller's
LoadBalancer**, and that LB is locked to **Catalyst Cloud's project
Egress Address** via `loadBalancerSourceRanges`. Anyone else hitting the
public URL is rejected at the Azure network layer before reaching the
ingress controller.

| Layer | What it gates |
|---|---|
| Azure network (`loadBalancerSourceRanges` on nginx-ingress LB) | non-Catalyst IPs |
| Catalyst App Id (token verification at Catalyst's edge) | bearer-token (`dapr-api-token`) presence + validity |
| MCPServer access policy | per-tool allow/deny per calling app-id |
| Keycloak JWT verification in `postgresql-mcp` itself (mandatory, always on) | Checked in application code (`servers/postgresql_mcp.py`, via the MCP SDK's `TokenVerifier`) — there's no Dapr sidecar for an MCPServer-resource-managed app-id, so this can't be a platform-level Component/Configuration. Per <https://docs.diagrid.io/develop/mcp/mcp-authentication#oauth-20-client-credentials>, the JWT itself is **Catalyst's own** — fetched via OAuth2 client-credentials configured on the MCPServer resource (`./oauth2/setup.sh`), not presented by the calling agent |
| Postgres role-scoped DB users | last line of defense — caps what each tool can actually execute |

> **Important caveat:** the Keycloak path `/keycloak/*` is also behind the
> same allowlist. Catalyst needs to fetch `/keycloak/realms/.../certs`
> (JWKS), so Catalyst's egress IPs must be allowed. Your operator browser
> wanting to reach the UI at `/` ALSO has to come from an allowlisted IP.
> Either add your office/VPN egress to `CATALYST_EGRESS_CIDRS`, or access
> the UI via `kubectl port-forward` instead.

## Deploy

```bash
cd k8s/

# 1. Create the Catalyst project + App IDs + MCPServer resource
#    (idempotent; safe to re-run)
cd .. && ./setup.sh && cd k8s

# 2. Get the project's Egress Address from the Catalyst Console
#    (or `diagrid project get $DIAGRID_PROJECT -o json | jq '.status'`)
EGRESS="20.x.x.x/32,20.x.x.y/32"

# 3. Install ingress-nginx (one-time; carries the DNS label + allowlist)
INGRESS_DNS_LABEL=securemcp \
AZURE_REGION=eastus \
CATALYST_EGRESS_CIDRS="$EGRESS" \
make install-ingress

# 4. Build + push images to Docker Hub (or your registry)
REGISTRY=tezizzm IMAGE_TAG=v1 make build-images

# 5. Install the secure-mcp chart
REGISTRY=tezizzm \
IMAGE_TAG=v1 \
DIAGRID_API_KEY=$YOUR_KEY \
INGRESS_DNS_LABEL=securemcp \
AZURE_REGION=eastus \
make install

# 6. Wait for Postgres + Keycloak to be ready (~3-5 min)
kubectl -n secure-mcp get pods --watch

# 7. Apply the MCPServer resource with the production FQDN
make register-appids

# 8. Confirm Catalyst can reach postgresql-mcp
diagrid mcpserver get postgresql-mcp --project secure-mcp-demo -o json | jq '.status'
# status may show "error" here — expected. postgresql-mcp's own JWT verification
# (servers/postgresql_mcp.py) already requires a JWT on every call, including
# Catalyst's own connectivity probe, and nothing supplies one until step 11.

# 9. Confirm Keycloak's OIDC discovery returns the right issuer
curl -s "http://securemcp.eastus.cloudapp.azure.com/keycloak/realms/secure-mcp/.well-known/openid-configuration" | jq .issuer
# expect: http://securemcp.eastus.cloudapp.azure.com/keycloak/realms/secure-mcp

# 10. Grant tool access (see README.md's "Granting + revoking")
cd .. && diagrid mcpserver access grant postgresql-mcp --caller analyst-mcp-client --allow-tools query --project secure-mcp-demo --wait
diagrid mcpserver access grant postgresql-mcp --caller ops-mcp-client     --allow-tools query,insert_employee,update_salary --project secure-mcp-demo --wait
diagrid mcpserver access grant postgresql-mcp --caller admin-mcp-client   --allow-tools query,insert_employee,update_salary,delete_employee,truncate_table --project secure-mcp-demo --wait

# 11. Enable Catalyst's own OAuth2 auth on the MCPServer resource — this is
#     what actually satisfies postgresql-mcp's JWT requirement from here on (see
#     "Trust model" above and README.md's "OIDC / bearer middleware"). Must
#     match the URL the chart already wired into postgresql-mcp's own env vars
#     (KEYCLOAK_PUBLIC_URL = http://<ingress-fqdn>/keycloak, from ingress.host).
export KEYCLOAK_PUBLIC_URL="http://securemcp.eastus.cloudapp.azure.com/keycloak"
cd .. && ./oauth2/setup.sh && cd k8s
diagrid mcpserver get postgresql-mcp --project secure-mcp-demo -o json | jq '.status'
# now expect "ready"
```

## URL shape

| Service       | Path on the shared FQDN | nginx behavior |
|---------------|--------------------------|----------------|
| ui-backend    | `/`                      | passthrough |
| keycloak      | `/keycloak`              | passthrough (Keycloak runs with `KC_HTTP_RELATIVE_PATH=/keycloak`) |
| postgresql-mcp | `/mcp`                   | rewrite to `/mcp` upstream |

Callers never hit these paths directly. Catalyst's MCP proxy endpoint
(`/v1.0/diagrid/mcp/postgresql-mcp` on the Catalyst HTTP endpoint) is the
only entry point. Catalyst reads the MCPServer resource's
`spec.endpoint.streamableHTTP.url` and proxies to
`http://securemcp.eastus.cloudapp.azure.com/mcp`.

## Looking up the Egress Address

```bash
diagrid project get $DIAGRID_PROJECT -o json | jq '.status'
```

The Catalyst Console at <https://catalyst.r1.diagrid.io/> also shows it
under the project's **Connectivity** or **Security** section.

## Skipping the allowlist for a quick test

`make install-ingress` without `CATALYST_EGRESS_CIDRS` will leave the LB
open to the internet. Fine for a 5-minute smoke test in an isolated
subscription; **never** for anything else. Re-running `make
install-ingress` with the CIDRs added is a no-downtime upgrade.

## Future: real domain + TLS

When a domain is available:
1. Point a `CNAME` at the Azure auto-FQDN (or update `Ingress.host`).
2. Add cert-manager + a ClusterIssuer for Let's Encrypt.
3. Annotate the Ingress with
   `cert-manager.io/cluster-issuer: letsencrypt-prod` and add a `tls:`
   section under the Ingress spec.
