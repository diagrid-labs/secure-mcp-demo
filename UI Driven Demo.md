# UI Driven Demo

Presenter runbook for the UI-first secure-mcp demo. The goal is to show an
audience how a database operation is governed by layered controls:

1. Catalyst App Id resolves the caller from its Catalyst token.
2. Catalyst ACL decides whether that app id can invoke the target MCP server.
3. Keycloak JWT middleware adds step-up auth for delete.
4. Postgres applies the final database role boundary.

The UI is the main surface. The CLI is used only to stage Catalyst state and to
make the control-plane changes visible.

---

## Environment

Use this block at the start of the demo terminal. These defaults match the
current deployed demo environment.

```bash
export PROJECT="${PROJECT:-security-demo}"

export PUBLIC_HOST="${PUBLIC_HOST:-securemcp.westeurope.cloudapp.azure.com}"
export KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL:-http://${PUBLIC_HOST}/keycloak}"

export KEYCLOAK_REALM="${KEYCLOAK_REALM:-secure-mcp}"
export KEYCLOAK_AUDIENCE="${KEYCLOAK_AUDIENCE:-https://secure-mcp-demo/}"
```

Derived values used later:

```bash
export KEYCLOAK_ISSUER="${KEYCLOAK_PUBLIC_URL}/realms/${KEYCLOAK_REALM}"
export KEYCLOAK_JWKS_URL="${KEYCLOAK_ISSUER}/protocol/openid-connect/certs"

export MCP_QUERY_URL="http://${PUBLIC_HOST}/mcp/query"
export MCP_WRITE_URL="http://${PUBLIC_HOST}/mcp/write"
export MCP_DELETE_URL="http://${PUBLIC_HOST}/mcp/delete"
```

---

## Setup Assumptions

Have these tabs open before starting:

- Demo UI: `http://${PUBLIC_HOST}/`
- Catalyst project: `$PROJECT`
- Catalyst Configurations / Policies
- Catalyst API logs
- Catalyst app graph
- Catalyst metrics
- Terminal at the repo root

The three MCP App IDs are:

```text
mcp-db-query
mcp-db-write
mcp-db-delete
```

The three Catalyst configurations are:

```text
db-query
db-write
db-delete
```

The calling agent App IDs are:

```text
analyst-agent
ops-agent
admin-agent
```

Quick health checks:

```bash
curl -s "http://${PUBLIC_HOST}/api/health" | jq .

diagrid appid get mcp-db-query  --project "$PROJECT" -o json | jq '.spec.appEndpoint'
diagrid appid get mcp-db-write  --project "$PROJECT" -o json | jq '.spec.appEndpoint'
diagrid appid get mcp-db-delete --project "$PROJECT" -o json | jq '.spec.appEndpoint'
```

Expected endpoints:

```text
$MCP_QUERY_URL
$MCP_WRITE_URL
$MCP_DELETE_URL
```

If you want to demonstrate creating the JWT middleware live, start with it
removed:

```bash
./oauth2/teardown.sh
```

That leaves the `db-delete` ACL in place but removes the bearer middleware from
the `db-delete` request pipeline.

Transition:

> "Everything we do in the UI is a real call through Catalyst into one of three
> MCP servers. The buttons show the exact verb and path, so we can connect the
> UI, Catalyst logs, and server behavior without guessing."

---

## 1. Start From Default Deny

Create or confirm the deny-by-default configurations:

```bash
diagrid configuration create db-query --project "$PROJECT" \
  --default-action deny \
  --policy analyst-agent:deny \
  --policy ops-agent:deny \
  --policy admin-agent:deny || true

diagrid configuration create db-write --project "$PROJECT" \
  --default-action deny \
  --policy analyst-agent:deny \
  --policy ops-agent:deny \
  --policy admin-agent:deny || true

diagrid configuration create db-delete --project "$PROJECT" \
  --default-action deny \
  --policy analyst-agent:deny \
  --policy ops-agent:deny \
  --policy admin-agent:deny || true
```

Attach the configurations to the MCP App IDs:

```bash
diagrid appid update mcp-db-query  --project "$PROJECT" --app-config db-query
diagrid appid update mcp-db-write  --project "$PROJECT" --app-config db-write
diagrid appid update mcp-db-delete --project "$PROJECT" --app-config db-delete
```

Show the state:

```bash
diagrid configuration list --project "$PROJECT"
diagrid configuration get db-query  --project "$PROJECT"
diagrid configuration get db-write  --project "$PROJECT"
diagrid configuration get db-delete --project "$PROJECT"
```

If you want to open the live editor for a configuration:

```bash
diagrid configuration edit db-query  --project "$PROJECT"
diagrid configuration edit db-write  --project "$PROJECT"
diagrid configuration edit db-delete --project "$PROJECT"
```

In Catalyst, open the three configurations and show that the default action is
deny.

Transition:

> "The baseline is not partial trust. New surfaces start closed. We explicitly
> grant the small set of calls each role needs."

---

## 2. Apply The RBAC Matrix

Apply the working policy:

```bash
diagrid configuration update db-query --project "$PROJECT" \
  --default-action deny \
  --policy analyst-agent:allow \
  --policy ops-agent:allow \
  --policy admin-agent:allow

diagrid configuration update db-write --project "$PROJECT" \
  --default-action deny \
  --policy analyst-agent:deny \
  --policy ops-agent:allow \
  --policy admin-agent:allow

diagrid configuration update db-delete --project "$PROJECT" \
  --default-action deny \
  --policy analyst-agent:deny \
  --policy ops-agent:deny \
  --policy admin-agent:allow
```

In Catalyst, open each configuration and point out the role-to-operation policy:

| Operation | Server | Allowed agents |
|---|---|---|
| Query | `mcp-db-query` | analyst, ops, admin |
| Write | `mcp-db-write` | ops, admin |
| Delete | `mcp-db-delete` | admin |

Transition:

> "This is RBAC at the MCP operation boundary. The agent does not get broad
> database access; it gets permission to invoke a specific tool server."

---

## 3. Run The UI Calls

In the UI, keep Step-up Auth off for now.

Run:

1. Acting as `analyst`, click `Query`.
2. Acting as `analyst`, click `Write`.
3. Acting as `admin`, click `Query`, `Write`, then `Delete`.

Expected:

- Analyst query succeeds.
- Analyst write is denied by Catalyst ACL.
- Admin query and write succeed.
- Admin delete succeeds only if JWT middleware has not been enabled yet.

Watch the Result panel:

- The top row shows the HTTP status and the path.
- `Catalyst App Id` shows token resolution.
- `Catalyst ACL` shows allow or deny.
- The DB table changes only when Postgres actually accepts the write/delete.

Transition:

> "Now jump to Catalyst logs. Notice the UI click is not one magic request. MCP
> clients may perform initialize, list tools, and call tool requests. The logs
> make that visible, which is useful for debugging and audit."

In Catalyst API logs, filter by:

```text
mcp-db-query
mcp-db-write
mcp-db-delete
```

---

## 4. Add Keycloak Step-Up Auth Live

Now add a second independent control on delete. Keycloak is running in the
cluster behind nginx at:

```text
$KEYCLOAK_PUBLIC_URL
```

The bearer middleware should validate tokens against:

```text
Issuer:
$KEYCLOAK_ISSUER

JWKS:
$KEYCLOAK_JWKS_URL

Audience:
$KEYCLOAK_AUDIENCE
```

You can create this live in Catalyst, or apply the staged files from the repo:

```bash
export DIAGRID_PROJECT="$PROJECT"
./oauth2/setup.sh
```

Verify the component:

```bash
diagrid component get bearer --project "$PROJECT" -o json | jq '.spec.metadata'
diagrid configuration get db-delete --project "$PROJECT" -o yaml
```

Transition:

> "Catalyst ACL says admin can reach the delete server. That is necessary, but
> not sufficient anymore. Delete now also requires a valid enterprise identity
> token from Keycloak."

---

## 5. Show The Failure Without JWT

In the UI:

1. Acting as `admin`.
2. Turn `Keycloak JWT` off.
3. Click `Delete`.

Expected:

- HTTP `401 Unauthorized`.
- `Catalyst App Id` passes.
- `Catalyst ACL` passes.
- `JWT middleware` fails.
- The result shows no traffic reached `mcp-db-delete`.
- The DB table does not change.

Callout:

> "This is the important shape: the admin's Catalyst identity is real and the
> ACL allows the operation, but the request still stops because the step-up JWT
> is missing."

---

## 6. Show The Header, Then Present JWT

Keep the Result panel visible.

Point out that the failed request shows either no `Authorization` header or a
masked invalid value on the JWT layer. Then:

1. Turn `Keycloak JWT` on.
2. Click `Delete` again.

Expected:

- HTTP `200 OK`.
- `Catalyst App Id` passes and shows a masked Catalyst token.
- `Catalyst ACL` passes.
- `JWT middleware` passes and shows a masked bearer token.
- The row is removed from the DB table.

The UI should show masked token examples like:

```text
dapr-api-token: diagrid://v1/79a...9d66a8f9
Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5...
```

Transition:

> "We are not asking the audience to trust the UI. The UI shows the headers,
> Catalyst logs show the edge decision, and the table only changes when the
> database changes."

---

## 7. Repeat The Three Operations With Step-Up Enabled

With `admin` selected and `Keycloak JWT` on:

1. Click `Query`.
2. Click `Write`.
3. Click `Delete`.

Expected:

- Query succeeds through `mcp-db-query`.
- Write succeeds through `mcp-db-write` and inserts a unique Demo Target row.
- Delete succeeds through `mcp-db-delete` and removes the Demo Target row.

Then switch to `analyst`:

1. Click `Query`.
2. Click `Write`.
3. Click `Delete`.

Expected:

- Query succeeds.
- Write fails at Catalyst ACL.
- Delete fails at Catalyst ACL before JWT matters.

Callout:

> "The JWT is not a magic admin override. Catalyst still enforces the app-id ACL
> first. A valid JWT does not turn analyst into admin."

---

## 8. Show Catalyst Graph And Metrics

Move to Catalyst:

1. Open API logs and show the recent successful and failed calls.
2. Open the app graph and show the three MCP servers as separate targets.
3. Open metrics and show request count / status distribution.

Narrative:

> "The separation is visible operationally. Query, write, and delete are
> different App IDs, different policies, and different audit trails. That is why
> we can reason about a destructive operation differently from a read."

Close with:

> "This is the demo in one sentence: the UI drives normal app behavior, while
> Catalyst and Keycloak make each security decision visible, auditable, and
> changeable without redeploying the agent or the MCP servers."

---

## Reset Between Runs

Return to deny-all:

```bash
diagrid configuration update db-query --project "$PROJECT" \
  --default-action deny \
  --policy analyst-agent:deny \
  --policy ops-agent:deny \
  --policy admin-agent:deny

diagrid configuration update db-write --project "$PROJECT" \
  --default-action deny \
  --policy analyst-agent:deny \
  --policy ops-agent:deny \
  --policy admin-agent:deny

diagrid configuration update db-delete --project "$PROJECT" \
  --default-action deny \
  --policy analyst-agent:deny \
  --policy ops-agent:deny \
  --policy admin-agent:deny
```

Optional: remove JWT middleware from delete if you want to demonstrate adding it
live again:

```bash
./oauth2/teardown.sh
```

Then refresh the UI and run one denied call to confirm the baseline.

---

## Quick Troubleshooting

If Catalyst shows no traffic:

```bash
diagrid appid get mcp-db-query  --project "$PROJECT" -o json | jq '.spec.appEndpoint'
diagrid appid get mcp-db-write  --project "$PROJECT" -o json | jq '.spec.appEndpoint'
diagrid appid get mcp-db-delete --project "$PROJECT" -o json | jq '.spec.appEndpoint'
```

If JWT fails when it should pass:

```bash
curl -s "${KEYCLOAK_PUBLIC_URL}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" | jq '.issuer'
diagrid component get bearer --project "$PROJECT" -o json | jq '.spec.metadata'
```

The issuer in both places must match exactly:

```text
$KEYCLOAK_ISSUER
```

If the DB table does not change after a successful write/delete:

```bash
curl -s "http://${PUBLIC_HOST}/api/employees" | jq '.rows | length'
kubectl -n secure-mcp logs deploy/secure-mcp-ui --tail=80
kubectl -n secure-mcp logs deploy/mcp-db-write --tail=80
kubectl -n secure-mcp logs deploy/mcp-db-delete --tail=80
```
