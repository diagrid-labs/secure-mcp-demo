/* =========================================================
   secure-mcp demo — state + backend bootstrap

   Single source of truth: window.__demo.
   - configured matrix (mirror of what Diagrid's control plane enforces;
     read-only here, edited via shell scripts)
   - jwtMiddlewareCfg: whether Diagrid's own OAuth2 client-credentials are
     configured on the MCPServer resource (global — not a per-call choice;
     no agent or UI call ever presents its own JWT). Toggling this in the
     UI actually calls oauth2/setup.sh's equivalent via /api/policy/apply.
   - employees rows (Postgres state, re-fetched after mutations)
   - last result (the gate trace the Agent Console renders)

   Two hooks for components:
     useDemo()      -> [state, actions]
     useDemoState() -> state only

   The actions go through fetch() to ui_backend. Local resolveCall is
   only a fallback if the backend is unreachable, so the prototype still
   tells some story standalone.
   ========================================================= */

const ROLES = ["analyst", "ops", "admin"];
const OPS   = ["query", "write", "delete"];

// Single combined MCP server — every op goes through the same app and the
// same Diagrid MCP proxy path.
const MCP_SERVER = "postgresql-mcp";
const MCP_PATH   = "/v1.0/diagrid/mcp/postgresql-mcp";

const VERB_OF = {
  query:  { name: "query",           args: "sql='SELECT * FROM employees ORDER BY id'" },
  write:  { name: "insert_employee", args: 'name="Demo Target", email="demo@diagrid.example"' },
  delete: { name: "delete_employee", args: 'where name="Demo Target"' },
};

const SEED_EMPLOYEES = [
  { id: 101, name: "Ravi Patel",     email: "ravi@diagrid.example" },
  { id: 102, name: "Yara Okafor",    email: "yara@diagrid.example" },
  { id: 103, name: "Linh Nguyen",    email: "linh@diagrid.example" },
  { id: 104, name: "Mateo Alvarez",  email: "mateo@diagrid.example" },
  { id: 105, name: "Sasha Petrov",   email: "sasha@diagrid.example" },
];

const DEFAULT_MATRIX = {
  analyst: { query: false, write: false, delete: false },
  ops:     { query: false, write: false, delete: false },
  admin:   { query: false, write: false, delete: false },
};

// ---------- store ----------
function createStore(initial) {
  let state = initial;
  const subs = new Set();
  return {
    get: () => state,
    set: (patch) => {
      state = (typeof patch === "function") ? patch(state) : { ...state, ...patch };
      subs.forEach((fn) => fn(state));
    },
    subscribe: (fn) => { subs.add(fn); return () => subs.delete(fn); },
  };
}

const NOW_HHMMSS = () => {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
};

const cloneMatrix = (m) => ROLES.reduce((acc, r) => {
  acc[r] = { ...m[r] };
  return acc;
}, {});

const initialState = {
  configured:       cloneMatrix(DEFAULT_MATRIX),
  jwtMiddlewareCfg: false,
  busyPolicy:       false,

  // Confirmation modal for the JWT step-up toggle — a click never applies
  // anything directly; only confirmJwtToggle() (fired by the modal's
  // Confirm button) does.
  jwtConfirmOpen:   false,
  jwtConfirmTarget: null,   // bool | null — captured at modal-open time

  // Illustrative client-side JWT preview (independent client_credentials
  // fetch against Keycloak's catalyst-proxy client — see README.md's
  // "OIDC / bearer middleware"). NOT the token Diagrid actually attaches
  // to any /api/invoke call; shown purely to demonstrate what one looks
  // like once step-up is enabled.
  jwtPreview:      null,    // null | { token, header, claims, fetchedAt, expiresInSeconds }
  jwtPreviewError: null,
  busyJwtPreview:  false,

  selectedRole: "ops",

  employees: [...SEED_EMPLOYEES],
  nextEmpId: 200,
  rowFlash:  null,         // { id, kind: "new" | "out" }

  lastResult: null,        // see makeResult shape below
  busyOp: null,            // "query" | "write" | "delete" while in-flight

  connected: true,
};

const store = createStore(initialState);

// ---------- backend bootstrap ----------
// Fetch real state from ui_backend on startup. If the backend isn't running
// (or any endpoint 4xx/5xx), we keep the simulated seed so the prototype
// still renders standalone.
async function _bootstrap() {
  try {
    const r = await fetch("/api/employees");
    if (r.ok) {
      const data = await r.json();
      if (Array.isArray(data.rows) && data.rows.length) {
        const maxId = data.rows.reduce((m, row) => Math.max(m, row.id || 0), 0);
        store.set({ employees: data.rows, nextEmpId: maxId + 1 });
      }
    }
  } catch (_) {}

  try {
    const r = await fetch("/api/policy/configured");
    if (r.ok) {
      const data = await r.json();
      if (data.matrix) {
        store.set({
          configured:       cloneMatrix(data.matrix),
          jwtMiddlewareCfg: !!data.jwtMiddleware,
        });
        // If JWT is already configured (e.g. after a page reload), fetch a
        // preview immediately so the gate trace's JWT middleware row has a
        // real token to show right away — not just right after toggling.
        if (data.jwtMiddleware) {
          actions.fetchJwtPreview();
        }
      }
    }
  } catch (_) {}

  _openEventStream();
}

// Subscribe to /api/events/stream so the connection indicator reflects
// whether the live event source is reachable. (Heartbeats themselves are
// surfaced via the inline gate trace's "<server> saw …" line.)
let _es = null;
function _openEventStream() {
  if (_es) return;
  try {
    _es = new EventSource("/api/events/stream");
    _es.addEventListener("tool_invoked", () => store.set({ connected: true }));
    _es.addEventListener("ping",         () => store.set({ connected: true }));
    _es.onopen  = () => store.set({ connected: true });
    _es.onerror = () => store.set({ connected: false });
  } catch (_) {
    store.set({ connected: false });
  }
}
_bootstrap();

// ---------- actions ----------
const actions = {
  selectRole(role) {
    store.set({ selectedRole: role });
  },

  // Opens the confirm modal instead of flipping state directly. The
  // target (enable vs. disable) is captured now, at open time, so a
  // stray external change (e.g. someone running oauth2/setup.sh in
  // another terminal) while the modal sits open can't silently change
  // what "confirm" ends up applying.
  openJwtConfirm() {
    const s = store.get();
    if (s.busyPolicy || s.busyJwtPreview) return;
    store.set({ jwtConfirmOpen: true, jwtConfirmTarget: !s.jwtMiddlewareCfg });
  },

  // Escape / click-outside / Cancel all call this. Never applies anything.
  closeJwtConfirm() {
    store.set({ jwtConfirmOpen: false, jwtConfirmTarget: null });
  },

  // The ONLY path that actually calls /api/policy/apply for the JWT flag.
  // Configures (or removes) Diagrid's own OAuth2 client-credentials auth
  // on the MCPServer resource — a GLOBAL setting, not per-call. No agent
  // or UI call ever presents its own JWT to postgresql-mcp; this is the only
  // thing that controls whether one reaches it at all.
  async confirmJwtToggle() {
    const s = store.get();
    if (s.busyPolicy || s.jwtConfirmTarget === null) return;
    const target = s.jwtConfirmTarget;

    store.set({ busyPolicy: true, jwtConfirmOpen: false, jwtConfirmTarget: null });

    try {
      await fetch("/api/policy/apply", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ matrix: s.configured, jwtMiddleware: target }),
      });
    } catch (_) {
      // Backend unreachable — fall through to the optimistic flip below.
    }

    let newCfg = target;
    try {
      const r = await fetch("/api/policy/configured");
      if (r.ok) {
        const data = await r.json();
        newCfg = !!data.jwtMiddleware;
      }
    } catch (_) {}

    store.set({ jwtMiddlewareCfg: newCfg, busyPolicy: false });

    if (newCfg) {
      // Enabling — fetch an illustrative token so the gate trace's JWT
      // middleware row has something real (truncated) to show on the
      // next successful call.
      actions.fetchJwtPreview();
    } else {
      // Disabling — clear any stale preview so the UI never shows a
      // valid-looking token while the server-side gate is off.
      store.set({ jwtPreview: null, jwtPreviewError: null });
    }
  },

  // Independent client-side JWT fetch — a client_credentials grant
  // against Keycloak's catalyst-proxy client, purely to have a real
  // (truncated-for-display) token available for the gate trace's JWT
  // middleware row. Does not touch jwtMiddlewareCfg/busyPolicy at all.
  async fetchJwtPreview() {
    const s = store.get();
    if (s.busyJwtPreview) return;
    store.set({ busyJwtPreview: true, jwtPreviewError: null });

    try {
      const r = await fetch("/api/jwt-preview", { method: "POST" });
      if (!r.ok) {
        const data = await r.json().catch(() => ({}));
        throw new Error(data.detail || `HTTP ${r.status}`);
      }
      const data = await r.json();
      store.set({ jwtPreview: data, busyJwtPreview: false });
    } catch (err) {
      store.set({ jwtPreviewError: String(err.message || err), busyJwtPreview: false });
    }
  },

  fireCall(op) {
    const s = store.get();
    if (s.busyOp) return;
    store.set({ busyOp: op });

    const role = s.selectedRole;

    (async () => {
      let result;
      try {
        const r = await fetch("/api/invoke", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ role, op, source: "ui" }),
        });
        if (!r.ok) throw new Error(`invoke HTTP ${r.status}`);
        result = await r.json();
      } catch (err) {
        // Backend unreachable — degrade to local resolver so the
        // prototype still tells some story standalone.
        console.warn("invoke fetch failed, falling back to local resolver:", err);
        result = resolveCall({
          role, op,
          configured: s.configured,
          jwtMiddleware: s.jwtMiddlewareCfg,
        });
      }

      const before = store.get();
      const next = { ...before, busyOp: null, lastResult: result };

      // On a successful mutation, re-fetch employees so the table mirrors
      // real Postgres state. Diff against prior rows to drive the flash.
      if (result.status === 200 && (op === "write" || op === "delete")) {
        try {
          const r = await fetch("/api/employees");
          if (r.ok) {
            const data = await r.json();
            const newRows = Array.isArray(data.rows) ? data.rows : before.employees;
            const beforeIds = new Set(before.employees.map((e) => e.id));
            const afterIds  = new Set(newRows.map((e) => e.id));
            if (op === "write") {
              const added = newRows.find((e) => !beforeIds.has(e.id));
              if (added) next.rowFlash = { id: added.id, kind: "new" };
            } else {
              const removed = before.employees.find((e) => !afterIds.has(e.id));
              if (removed) next.rowFlash = { id: removed.id, kind: "out" };
            }
            next.employees = newRows;
            const maxId = newRows.reduce((m, row) => Math.max(m, row.id || 0), 0);
            next.nextEmpId = maxId + 1;
          }
        } catch (_) {}
      }

      store.set(next);
      if (next.rowFlash) {
        setTimeout(() => store.set({ rowFlash: null }), 800);
      }
    })();
  },
};

// ---------- local fallback resolver ----------
// Used only when the backend isn't reachable. Keeps the prototype
// renderable standalone (e.g. opened from a file:// URL). Real demos run
// against the backend and never hit this path.
//
// Gate order matches the real architecture: Diagrid's MCPServer access
// policy is checked first, at Diagrid's edge — an ACL deny never reaches
// postgresql-mcp at all. postgresql-mcp's own JWT verification (Diagrid's own
// OAuth2 auth, see README.md's "OIDC / bearer middleware") is the second,
// independent gate, checked on every op alike — not just delete.
function resolveCall({ role, op, configured, jwtMiddleware }) {
  const verb = VERB_OF[op];
  const t    = NOW_HHMMSS();

  if (!configured[role][op]) {
    return makeResult({
      kind: "acl-deny",
      status: 403,
      role, op, server: MCP_SERVER, jwt: jwtMiddleware, source: "ui", t, verb,
      sawTraffic: false,
      reason: `'${role}' has no allow rule for tool '${verb.name}'`,
    });
  }

  if (!jwtMiddleware) {
    return makeResult({
      kind: "jwt-deny",
      status: 401,
      role, op, server: MCP_SERVER, jwt: false, source: "ui", t, verb,
      sawTraffic: false,
      reason: "Diagrid's own OAuth2 auth isn't configured on the MCPServer resource yet",
    });
  }

  return makeResult({
    kind: "ok",
    status: 200,
    role, op, server: MCP_SERVER, jwt: true, source: "ui", t, verb,
    sawTraffic: true,
    reason: null,
  });
}

function makeResult(o) {
  return {
    ...o,
    durationMs: o.kind === "ok" ? randMs(110, 240) : randMs(35, 90),
    path: MCP_PATH,
    method: "POST",
    headersSent: {},      // backend-driven; empty in the fallback path
  };
}
function randMs(a, b) { return Math.round(a + Math.random() * (b - a)); }

// ---------- React hook ----------
function useDemo() {
  const [s, setS] = React.useState(store.get());
  React.useEffect(() => store.subscribe(setS), []);
  return [s, actions];
}

window.__demo = { store, actions, useDemo, ROLES, OPS, MCP_SERVER, MCP_PATH, VERB_OF };
