# Catalyst integration — Cloud + nginx-ingress

Catalyst Cloud hosts the Dapr runtime centrally. Per
<https://docs.diagrid.io/develop/connect>, your apps don't run any
in-cluster sidecar — they expose an HTTP endpoint and Catalyst forwards
inbound invocations to it. This chart uses the **app endpoint**
connection model, with all three MCP servers reachable via path-based
routing on a single nginx-ingress.

## Trust model

The MCP servers are on `ClusterIP` Services — not directly reachable from
outside. The only public surface is the **nginx-ingress controller's
LoadBalancer**, and that LB is locked to **Catalyst Cloud's project
Egress Address** via `loadBalancerSourceRanges`. Anyone else hitting the
public URL is rejected at the Azure network layer before reaching the
ingress controller.

| Layer | What it gates |
|---|---|
| Azure network (`loadBalancerSourceRanges` on nginx-ingress LB) | non-Catalyst IPs (and Keycloak's `/keycloak/*` — same allowlist) |
| Catalyst App Id (token verification at Catalyst's edge) | bearer-token (`dapr-api-token`) presence + validity |
| Catalyst ACL | role-vs-app-id allow/deny |
| Catalyst JWT middleware (`mcp-db-delete` only) | Keycloak-issued step-up JWT |

The "MCP servers see nothing un-authorized" demo story still holds because
network-layer + Catalyst-layer gates all run before any traffic hits the
upstream pods.

> **Important caveat:** the Keycloak path `/keycloak/*` is also behind the
> same allowlist. Catalyst needs to fetch `/keycloak/realms/.../certs`
> (JWKS), so Catalyst's egress IPs must be allowed. Your operator browser
> wanting to reach the UI at `/` ALSO has to come from an allowlisted IP.
> Either add your office/VPN egress to `CATALYST_EGRESS_CIDRS`, or run
> the operator UI via `kubectl port-forward` instead.

## Deploy

```bash
cd k8s/

# 1. Get the project's Egress Address from the Catalyst Console
#    (or `diagrid project get $DIAGRID_PROJECT -o json` — field name has
#    moved across CLI versions; check `--help`).
EGRESS="20.x.x.x/32,20.x.x.y/32"

# 2. Install ingress-nginx (one-time; carries the DNS label + allowlist)
INGRESS_DNS_LABEL=securemcp \
AZURE_REGION=eastus \
CATALYST_EGRESS_CIDRS="$EGRESS" \
make install-ingress

# 3. Install the secure-mcp chart
REGISTRY=ghcr.io/yourorg \
DIAGRID_API_KEY=$YOUR_KEY \
INGRESS_DNS_LABEL=securemcp \
AZURE_REGION=eastus \
make install

# 4. Wait for the Azure LB IP to provision (~1-2 min)
kubectl -n ingress-nginx get svc --watch

# 5. Confirm Keycloak's OIDC discovery returns the right issuer
curl -s "http://securemcp.eastus.cloudapp.azure.com/keycloak/realms/secure-mcp/.well-known/openid-configuration" | jq .issuer
# expect: http://securemcp.eastus.cloudapp.azure.com/keycloak/realms/secure-mcp

# 6. Register each MCP server's path with Catalyst as its app-endpoint
make register-appids

# 7. Verify Catalyst can reach the servers
diagrid appid get mcp-db-query --project secure-mcp-demo -o json | jq '.status'
```

## URL shape

| Service       | Path on the shared FQDN | nginx behavior |
|---------------|--------------------------|----------------|
| ui-backend    | `/`                      | passthrough |
| keycloak      | `/keycloak`              | passthrough (Keycloak runs with `KC_HTTP_RELATIVE_PATH=/keycloak`) |
| mcp-db-query  | `/mcp/query`             | rewrite to `/mcp` upstream |
| mcp-db-write  | `/mcp/write`             | rewrite to `/mcp` upstream |
| mcp-db-delete | `/mcp/delete`            | rewrite to `/mcp` upstream |

So Catalyst's invocation of, say, the query app-id ends up POSTing
`http://securemcp.eastus.cloudapp.azure.com/mcp/query/mcp` (Catalyst
appends `/<method>` to the registered app-endpoint), nginx-ingress
rewrites the path to `/mcp`, and the FastMCP server receives the request
on the path it expects.

## Looking up the Egress Address

The exact CLI invocation has moved between Diagrid CLI versions. Try:

```bash
diagrid project get $DIAGRID_PROJECT -o json | jq '.status'
```

If the egress field isn't obvious in the JSON, the Catalyst Console at
<https://catalyst.r1.diagrid.io/> shows it under the project's
**Connectivity** or **Security** section. Plug those CIDR(s) into
`CATALYST_EGRESS_CIDRS` for both `make install-ingress` (where it lands
as `loadBalancerSourceRanges`) and any external systems that talk to the
UI backend.

## Skipping the allowlist for a quick test

`make install-ingress` without `CATALYST_EGRESS_CIDRS` will leave the LB
open to the internet. Fine for a 5-minute smoke test in an isolated
subscription; **never** for anything else. Re-running `make
install-ingress` with the CIDRs added is a no-downtime upgrade.

## Future: real domain + TLS

When a domain is available:
1. Point a `CNAME` at the Azure auto-FQDN (or update Ingress.host to the
   real hostname and let your existing DNS handle it).
2. Add cert-manager + a ClusterIssuer for Let's Encrypt.
3. Annotate the Ingress with
   `cert-manager.io/cluster-issuer: letsencrypt-prod` and add a `tls:`
   section under the Ingress spec.

Switching from path-based to hostname-based routing (one hostname per
service, with hostname-distinguished Ingress rules) is also viable
once you have wildcard DNS or per-service records.
