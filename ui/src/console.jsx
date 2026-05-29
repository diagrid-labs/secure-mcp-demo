/* Agent Console — Role, JWT toggle, three operation buttons, + the
   HTTP Response gate trace inline below. The buttons surface the actual
   path + verb that will hit Catalyst; the response surfaces the masked
   tokens the backend sent and which gate (App Id / ACL / JWT) decided.
*/

function AgentConsole() {
  const [s, a] = window.__demo.useDemo();
  const { ROLES, OPS, SERVER_OF } = window.__demo;
  const lastResult = s.lastResult;
  const jwtRequired = s.jwtMiddlewareCfg;   // policy state from backend bootstrap

  return (
    <section className="card" data-screen-label="Agent Console">
      <div className="card-h">
        <div>
          <div className="eyebrow">01 · Agent</div>
          <h2>Console</h2>
        </div>
        <div className="sub">
          {lastResult ? (
            <span>
              last · <b style={{ color: "var(--fg)" }}>{lastResult.role}</b> · {lastResult.op}{" "}
              <span style={{ opacity: 0.6 }}>· {lastResult.t}</span>
            </span>
          ) : (
            "no calls yet"
          )}
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
            <div className="field-h">Acting as</div>
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
            <div className="field-h">Step-up auth</div>
            <div
              className={`jwt-switch ${s.jwtPresented ? "on" : ""}`}
              role="switch"
              aria-checked={s.jwtPresented}
              tabIndex={0}
              onClick={a.toggleJwtPresented}
              onKeyDown={(e) => {
                if (e.key === "Enter" || e.key === " ") { e.preventDefault(); a.toggleJwtPresented(); }
              }}
              style={{ cursor: "pointer", width: "100%", justifyContent: "space-between" }}
            >
              <div className="lbl">
                <span className="top">Keycloak JWT</span>
                <span className="bot">{s.jwtPresented ? "presented alongside Catalyst token" : "not presented"}</span>
              </div>
              <button className="switch" aria-hidden="true" tabIndex={-1} />
            </div>
          </div>
        </div>

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
            <div className="field-h">Fire a call</div>
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
                    POST /v1.0/invoke/{SERVER_OF[op]}/method/mcp
                    {op === "delete" && jwtRequired ? " · requires JWT" : ""}
                  </span>
                </button>
              ))}
            </div>
          </div>

          <div>
            <div className="field-h">Result</div>
            <HttpResponse lastResult={lastResult} />
          </div>
        </div>
      </div>
    </section>
  );
}

function HttpResponse({ lastResult }) {
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
  const path = r.path || `/v1.0/invoke/${r.server}/method/mcp`;

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
        <GateTrace result={r} />
        <SawTraffic result={r} />
      </div>
    </div>
  );
}

function statusText(s) {
  return s === 200 ? "OK" : s === 401 ? "Unauthorized" : s === 403 ? "Forbidden" : "";
}

function GateTrace({ result }) {
  const r = result;
  const headers = r.headersSent || {};
  const daprToken = headers["dapr-api-token"];
  const authHdr   = headers["Authorization"];
  let edge, acl, jwt;

  if (r.kind === "ok") {
    edge = { state: "passed", detail: "bearer token resolved to app-id" };
    acl  = { state: "passed", detail: `'${r.role}' allowed on ${r.server}` };
    if (r.op === "delete") {
      jwt = r.jwt
        ? { state: "passed", detail: "JWT verified (iss, aud, sig)" }
        : { state: "skipped", detail: "not required for this op" };
    } else {
      jwt = { state: "skipped", detail: "not required for this op" };
    }
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
        sub={jwt.state === "skipped" && r.op !== "delete" ? "only enforced on mcp-db-delete" : null}
        header={authHdr ? { k: "Authorization", v: authHdr } : null}
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

window.AgentConsole = AgentConsole;
