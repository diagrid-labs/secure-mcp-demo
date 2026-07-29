/* Agent Console — Role, JWT toggle, three operation buttons, + the
   HTTP Response gate trace inline below. The buttons surface the actual
   path + verb that will hit Catalyst; the response surfaces the masked
   tokens the backend sent and which gate (App Id / ACL / JWT) decided.
*/

function AgentConsole() {
  const [s, a] = window.__demo.useDemo();
  const { ROLES, OPS, MCP_PATH } = window.__demo;
  const lastResult = s.lastResult;
  // Whether Catalyst's own OAuth2 auth is configured on the MCPServer
  // resource — a global setting (see oauth2/setup.sh), not per-call. JWT
  // verification itself is always required, on every op; this reflects
  // whether anything currently satisfies it.
  const jwtConfigured = s.jwtMiddlewareCfg;

  return (
    <section className="card" data-screen-label="Agent Console">
      <div className="card-h">
        <div>
          <h2>MCP Client</h2>
        </div>
      </div>

      <div className="card-body">
        {/* Row 1 — identity controls side by side */}
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "1fr 1fr",
            gap: 24,
            paddingBottom: 20,
            borderBottom: "1px dashed var(--rule, rgba(0,0,0,0.07))",
          }}
        >
          <div>
            <div className="field-h">Agent role:</div>
            <div className="segmented" role="tablist" aria-label="Agent role">
              {ROLES.map((r) => (
                <button
                  key={r}
                  role="tab"
                  aria-pressed={s.selectedRole === r}
                  onClick={() => a.selectRole(r)}
                >
                  <RoleGlyph role={r} />
                  {r}
                </button>
              ))}
            </div>
          </div>

          <div>
            <div className="field-h">Catalyst OAuth2 auth (Keycloak)</div>
            <div className={`jwt-status-panel ${jwtConfigured ? "on" : "off"} ${s.busyPolicy ? "busy" : ""}`}>
              <div className="lbl">
                <span className="top">Keycloak JWT</span>
                <span className="bot">
                  {s.busyPolicy
                    ? "updating…"
                    : jwtConfigured
                      ? "Catalyst attaches its own token to every call"
                      : "not configured — every call fails, on every op"}
                </span>
              </div>
              <button
                type="button"
                className={`btn ${jwtConfigured ? "btn-outline" : "btn-primary"}`}
                onClick={a.openJwtConfirm}
                disabled={s.busyPolicy}
                aria-haspopup="dialog"
              >
                {s.busyPolicy ? "Updating…" : jwtConfigured ? "Turn off…" : "Turn on…"}
              </button>
            </div>
          </div>
        </div>

        {s.jwtConfirmOpen && <JwtConfirmModal s={s} a={a} />}

        {/* Row 2 — fire a call + result side by side */}
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "1fr 1.4fr",
            gap: 28,
            paddingTop: 20,
            alignItems: "start",
          }}
        >
          <div>
            <div className="field-h">MCP tool call:</div>
            <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
              {OPS.map((op) => (
                <button
                  key={op}
                  className={`op-btn ${op === "delete" ? "destructive" : ""} ${s.busyOp === op ? "busy" : ""}`}
                  onClick={() => a.fireCall(op)}
                  disabled={!!s.busyOp}
                  data-op={op}
                  style={{ textAlign: "left", width: "100%" }}
                >
                  <span className="verb">{op[0].toUpperCase() + op.slice(1)}</span>
                  <span className="sql">{sqlFor(op)}</span>
                  <span
                    className="target"
                    style={{ font: "500 11px var(--font-mono)", letterSpacing: "0.02em" }}
                  >
                    POST {MCP_PATH} · requires JWT
                  </span>
                </button>
              ))}
            </div>
          </div>

          <div>
            <div className="field-h">Result:</div>
            <HttpResponse lastResult={lastResult} jwtToken={s.jwtPreview ? s.jwtPreview.token : null} />
          </div>
        </div>
      </div>
    </section>
  );
}

function HttpResponse({ lastResult, jwtToken }) {
  if (!lastResult) {
    return (
      <div className="http-inline idle">
        <div className="http-bar">
          <div className="status">— · —</div>
          <div className="verb-line">
            <span className="method">CALL</span>
            <span style={{ color: "var(--neutral-400)" }}>awaiting first action</span>
          </div>
        </div>
        <div className="gate-trace">
          <div className="empty-hint">
            <div className="big">No call yet</div>
            fire a query, write, or delete above to see the gate trace.
          </div>
        </div>
      </div>
    );
  }

  const r = lastResult;
  const isOk = r.status === 200;
  const klass = isOk ? "ok" : "fail";
  const path = r.path || window.__demo.MCP_PATH;

  return (
    <div className={`http-inline ${klass}`}>
      <div className="http-bar">
        <div className="status">
          {r.status} <span style={{ fontWeight: 400, fontSize: 16, color: "var(--neutral-500)" }}>{statusText(r.status)}</span>
        </div>
        <div className="verb-line">
          <span className="method">{r.method || "POST"}</span>
          <span>{path}</span>
        </div>
        <div className={`source-pill ${r.source === "external" ? "external" : ""}`}>
          {r.source === "external" ? null : <span className="ic" />}
          {r.source === "external" ? "from terminal" : `${r.role} · ${r.op}`}
        </div>
      </div>

      <div className="gate-trace">
        <GateTrace result={r} jwtToken={jwtToken} />
        <SawTraffic result={r} />
      </div>
    </div>
  );
}

function statusText(s) {
  return s === 200 ? "OK" : s === 401 ? "Unauthorized" : s === 403 ? "Forbidden" : "";
}

// Shows only a prefix of the illustrative JWT — this is Catalyst's own
// token (see README.md's "OIDC / bearer middleware"), not something that
// needs to stay secret from this UI's own audience, but the full token is
// long and not the point; a recognizable subset is enough to show it's real.
function truncateJwt(token, prefixLen = 40) {
  if (!token) return "";
  return token.slice(0, prefixLen) + "...";
}

function GateTrace({ result, jwtToken }) {
  const r = result;
  const headers = r.headersSent || {};
  const daprToken = headers["dapr-api-token"];
  const authHdr   = headers["Authorization"];
  let edge, acl, jwt;

  if (r.kind === "ok") {
    edge = { state: "passed", detail: "bearer token resolved to app-id" };
    acl  = { state: "passed", detail: `'${r.role}' allowed on ${r.server}` };
    // Required on every op, always — mcp-server verifies a JWT on every
    // call, no exceptions for query/write. A successful call only ever
    // happens because Catalyst's own token satisfied it.
    jwt = { state: "passed", detail: "JWT verified — Catalyst's own token (iss, aud, sig)" };
  } else if (r.kind === "edge-fail") {
    edge = { state: "failed", detail: r.reason };
    acl  = { state: "skipped", detail: "not reached" };
    jwt  = { state: "skipped", detail: "not reached" };
  } else if (r.kind === "acl-deny") {
    edge = { state: "passed", detail: "bearer token resolved to app-id" };
    acl  = { state: "failed", detail: r.reason };
    jwt  = { state: "skipped", detail: "not reached" };
  } else if (r.kind === "jwt-deny") {
    edge = { state: "passed", detail: "bearer token resolved to app-id" };
    acl  = { state: "passed", detail: `'${r.role}' allowed on ${r.server}` };
    jwt  = { state: "failed", detail: r.reason };
  }

  return (
    <>
      <GateRow
        which="edge"
        name="Catalyst App Id"
        detail={edge.detail}
        state={edge.state}
        header={daprToken ? { k: "dapr-api-token", v: daprToken } : null}
      />
      <GateRow
        which="acl"
        name="Catalyst ACL"
        detail={acl.detail}
        state={acl.state}
      />
      <GateRow
        which="jwt"
        name="JWT middleware"
        detail={jwt.detail}
        state={jwt.state}
        header={
          r.kind === "ok" && jwtToken
            ? { k: "Authorization", v: `Bearer ${truncateJwt(jwtToken)}` }
            : (authHdr ? { k: "Authorization", v: authHdr } : null)
        }
      />
    </>
  );
}

function GateRow({ which, name, detail, state, sub, header }) {
  const glyph = state === "passed" ? "✓" : state === "failed" ? "✗" : "–";
  return (
    <div className={`gate-row ${which} ${state}`} aria-label={`${name} ${state}`}>
      <span className="icn">{glyph}</span>
      <div className="name">
        {name}
        {sub ? <div style={{ font: "500 11px var(--font-mono)", color: "var(--neutral-500)", letterSpacing: "0.02em", marginTop: 2 }}>{sub}</div> : null}
      </div>
      <div className="detail">
        {detail}
        {header ? (
          <div
            style={{
              marginTop: 4,
              font: "500 11px/1.5 var(--font-mono)",
              letterSpacing: "0.01em",
              color: "var(--neutral-500)",
              display: "flex",
              gap: 6,
              flexWrap: "wrap",
            }}
          >
            <span>{header.k}:</span>
            <span style={{ color: "var(--fg)", wordBreak: "break-all" }}>{header.v}</span>
          </div>
        ) : null}
      </div>
    </div>
  );
}

function SawTraffic({ result }) {
  const r = result;
  const sawIt = r.sawTraffic;
  return (
    <div className={`saw-traffic ${sawIt ? "" : "empty"}`}>
      <span className="lbl">{r.server} saw</span>
      <span className="v">
        {sawIt
          ? <><b>{r.verb.name}</b><span className="args">({r.verb.args})</span></>
          : "no traffic"}
      </span>
    </div>
  );
}

function sqlFor(op) {
  if (op === "query")  return "SELECT * FROM employees";
  if (op === "write")  return "INSERT … 'Demo Target'";
  if (op === "delete") return "DELETE … name='Demo Target'";
  return "";
}

/* Confirmation modal for the JWT step-up toggle. A click on the button in
   AgentConsole only opens this — nothing is applied until Confirm. */
function JwtConfirmModal({ s, a }) {
  const enabling = s.jwtConfirmTarget === true;
  const dialogRef = React.useRef(null);

  React.useEffect(() => {
    const onKey = (e) => { if (e.key === "Escape") a.closeJwtConfirm(); };
    window.addEventListener("keydown", onKey);
    dialogRef.current?.focus();
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return (
    <>
      <div className="scrim open" onClick={a.closeJwtConfirm} />
      <div
        className="confirm-modal"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="jwt-confirm-title"
        aria-describedby="jwt-confirm-body"
        tabIndex={-1}
        ref={dialogRef}
        onClick={(e) => e.stopPropagation()}
      >
        <h2 id="jwt-confirm-title">
          {enabling ? "Turn on Keycloak JWT enforcement?" : "Turn off Keycloak JWT enforcement?"}
        </h2>
        <div id="jwt-confirm-body" className="confirm-modal-body">
          {enabling ? (
            <>
              <p>
                This configures Catalyst's own OAuth2 client-credentials on the{" "}
                <code>mcp-server</code> MCPServer resource. From then on,{" "}
                <b>every mcp-server call will require a valid Keycloak JWT</b> —
                Catalyst fetches and attaches its own token automatically, on
                every call, for every role.
              </p>
              <p className="fine">
                This will also fetch a real, illustrative JWT from Keycloak using
                the same <code>catalyst-proxy</code> client identity Catalyst
                itself uses, purely to show you what that token looks like —
                it is <b>not</b> the literal token Catalyst attaches to any
                specific call.
              </p>
            </>
          ) : (
            <p>
              This removes Catalyst's OAuth2 auth from the <code>mcp-server</code>{" "}
              MCPServer resource. From then on, <b>every call will start failing
              with 401</b>, regardless of what the ACL matrix allows — nothing
              will be supplying a JWT anymore.
            </p>
          )}
        </div>
        <div className="confirm-modal-actions">
          <button className="btn btn-ghost" onClick={a.closeJwtConfirm}>Cancel</button>
          <button
            className={`btn ${enabling ? "btn-primary" : "btn-outline"}`}
            onClick={a.confirmJwtToggle}
            autoFocus
          >
            {enabling ? "Confirm — enable" : "Confirm — disable"}
          </button>
        </div>
      </div>
    </>
  );
}

window.AgentConsole = AgentConsole;
