/* =========================================================
   secure-mcp demo — state + backend bootstrap

   Single source of truth: window.__demo.
   - configured matrix (mirror of what Catalyst's control plane enforces;
     read-only here, edited via shell scripts)
   - jwt middleware on/off (mirror)
   - selected role + jwt-presented (per-call concept)
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

const SERVER_OF = {
  query:  "mcp-db-query",
  write:  "mcp-db-write",
  delete: "mcp-db-delete",
};

const VERB_OF = {
  query:  { name: "list_employees",  args: "limit=100" },
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

  selectedRole: "ops",
  jwtPresented: false,

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

  toggleJwtPresented() {
    store.set((s) => ({ ...s, jwtPresented: !s.jwtPresented }));
  },

  fireCall(op) {
    const s = store.get();
    if (s.busyOp) return;
    store.set({ busyOp: op });

    const role = s.selectedRole;
    const jwt  = s.jwtPresented;

    (async () => {
      let result;
      try {
        const r = await fetch("/api/invoke", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ role, op, jwtPresented: jwt, source: "ui" }),
        });
        if (!r.ok) throw new Error(`invoke HTTP ${r.status}`);
        result = await r.json();
      } catch (err) {
        // Backend unreachable — degrade to local resolver so the
        // prototype still tells some story standalone.
        console.warn("invoke fetch failed, falling back to local resolver:", err);
        result = resolveCall({
          role, op, jwt,
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
function resolveCall({ role, op, jwt, configured, jwtMiddleware }) {
  const server = SERVER_OF[op];
  const verb   = VERB_OF[op];
  const t      = NOW_HHMMSS();

  if (!configured[role][op]) {
    return makeResult({
      kind: "acl-deny",
      status: 403,
      role, op, server, jwt, source: "ui", t, verb,
      sawTraffic: false,
      reason: `'${role}' has no allow rule for ${server}`,
    });
  }

  if (op === "delete" && jwtMiddleware && !jwt) {
    return makeResult({
      kind: "jwt-deny",
      status: 401,
      role, op, server, jwt, source: "ui", t, verb,
      sawTraffic: false,
      reason: "no JWT presented (mcp-db-delete requires step-up)",
    });
  }

  return makeResult({
    kind: "ok",
    status: 200,
    role, op, server, jwt, source: "ui", t, verb,
    sawTraffic: true,
    reason: null,
  });
}

function makeResult(o) {
  return {
    ...o,
    durationMs: o.kind === "ok" ? randMs(110, 240) : randMs(35, 90),
    path: `/v1.0/invoke/${o.server}/method/mcp`,
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

window.__demo = { store, actions, useDemo, ROLES, OPS, SERVER_OF, VERB_OF };
