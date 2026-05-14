# Known Issues

## `agent-framework` 1.3.0 stable is broken — pinned to 1.0.0b260507 beta

### Symptom

With `agent-framework`, `agent-framework-core`, and `agent-framework-openai` all
at the 1.3.0 stable release, importing anything from the package fails:

```
ImportError: cannot import name '__version__' from 'agent_framework'
  (/.../site-packages/agent_framework/__init__.py)
```

`agent_framework/__init__.py` ships **empty** (0 bytes), but
`agent_framework/observability.py` does:

```python
from . import __version__ as version_info
```

…which blows up at import time, taking down anything downstream
(`agent_framework._agents`, `._tools`, `._mcp`, etc.).

The previous demo (`catalyst-mcp-governance`) installed with
`pip install --pre -r requirements.txt` and pulled the older
`1.0.0b260507` beta line, where `__init__.py` correctly re-exports the public
surface (`Agent`, `MCPStreamableHTTPTool`, etc.) and defines `__version__`.

### Reproduce

```bash
uv pip install --prerelease=allow agent-framework
uv run python -c "from agent_framework import Agent"
```

### Workaround (current)

`agents/requirements.txt` pins to `==1.2.2` for `agent-framework`,
`agent-framework-core`, and `agent-framework-openai` — the last stable
release before 1.3.0 introduced the empty-init regression. Install with
`uv pip install -r agents/requirements.txt`.

### Ask for engineering

The 1.3.0 stable release appears to have shipped without populating
`agent_framework/__init__.py`. Two paths forward upstream:

1. Restore the re-exports + `__version__` in the meta-package's `__init__.py`,
   matching what the 1.0.0b series did, **or**
2. Update internal imports (e.g. `observability.py`) to source `__version__`
   from a sibling module (`_version.py`) rather than the package init.

Either fix would unpin us. The empty-init pattern is fine for PEP 420 namespace
packages, but the codebase still treats `agent_framework` as a regular package
internally — those two assumptions need to align.

### Affected files in this repo
- `agents/requirements.txt`

---

## `diagrid dev run` hangs after wrapped command exits, breaks neighbor tunnels on auto-teardown

### Symptom

`diagrid dev run --app-id <agent> -- <one-shot-script>` does not exit after
the wrapped script finishes — the tunnel stays open. Useful for interactive
sessions, terrible for scripted multi-agent runs.

Workarounds we tried, in order:

1. **`-y` flag (skip confirmation)** — no effect; it hangs identically.
2. **`pkill -INT -f "diagrid dev run.*<agent>"` after wrapped-cmd exit line** —
   advances the script, but **also breaks the server-side tunnels** in
   another terminal. The next probe gets HTTP 502 (Catalyst can't reach
   upstream). Server-side terminal eventually prints:
   ```
   failed to connect App ID "mcp-db-schema" ... workload identity join
   token already consumed — disconnect existing tunnel and retry
   ```
   The "join token" is one-shot; once an established tunnel dies, the same
   token can't be reused.
3. **`diagrid dev stop --app-id <agent>` after wrapped-cmd exit line** —
   same 502 cascade as `pkill`. Implies the cleanup is broader than the
   targeted app-id flag suggests.

### Current workaround

`run_demo.sh` does **not** wrap the agent invocations in `diagrid dev run`
at all. Instead it:

1. Reads the project's `DAPR_HTTP_ENDPOINT` via `diagrid project get`
2. For each agent role, reads its `apiToken` via `diagrid appid get`
3. Calls `agents/probe.py` directly with those values in env

This skips the agent-side dev session entirely, which sidesteps the
tunnel-cascade bug. Servers still run under `diagrid dev run -f dev.yaml`,
so the Diagrid multi-app inbound flow is preserved.

For **single-shot live demo scenes** (one agent, one task, interactive),
`diagrid dev run --app-id <agent>` works fine — the cascade only matters
when scripting multiple agents in sequence.

Tried and rejected:
- `pkill -INT diagrid dev run` after wrapped-cmd exit → server tunnels die
- `diagrid dev stop --app-id <agent>` → same cascade
- Letting `diagrid dev run` hang and using SIGINT trap to advance → fragile,
  state degrades across runs, requires per-run `./reset.sh`

### Ask for engineering

1. Provide an explicit `--exit-after-wrapped` or `--oneshot` flag for
   `diagrid dev run` that exits cleanly after the wrapped command, without
   touching other app-ids' sessions in the same project.
2. Investigate why `diagrid dev stop --app-id <X>` and `pkill` on one
   `diagrid dev run` process both seem to invalidate other app-ids' join
   tokens. Targeted teardown should be local to the specified app-id.
3. Make join tokens reusable on graceful disconnect, or provide a
   `diagrid dev reconnect --app-id <X>` to re-mint without a full restart.

### Affected files in this repo
- `run_demo.sh`

---

## Server tunnels go stale after extended idle; `dev status` doesn't reflect it

### Symptom

After ~20+ minutes idle, every previously-allowed call through Catalyst
returns HTTP 502. Denied calls still correctly return 403 (the ACL layer
runs at Catalyst's edge, before the tunnel). The local MCP server is
healthy — `curl localhost:8001/mcp` returns valid responses.

Meanwhile, `diagrid dev status` reports all four app-ids as `ready`,
which is misleading: that's the dev *session* state, not the live
tunnel state.

### Workaround

Recover by bouncing the server-side dev session:
1. Ctrl+C in Terminal 1 (the `diagrid dev run -f dev.yaml` process)
2. `./reset.sh`
3. Restart `diagrid dev run --project secure-mcp-demo -f dev.yaml`

### Ask for engineering

1. `diagrid dev status` should reflect actual tunnel liveness, not just
   session existence.
2. Tunnels should either self-restore on idle-disconnect or be kept warm
   by the CLI itself (heartbeat).
3. If the design intent is short-lived tunnels, surface the timeout
   value and a clear "tunnel expired, restart needed" message instead
   of returning 502 silently.

### Affected files in this repo
- (none — workaround is operational)

---

## `diagrid dev run` doesn't reliably kill its wrapped child processes on shutdown

### Symptom

After Ctrl+C'ing `diagrid dev run -f dev.yaml`, the next attempt to start
it fails with:

```
ERROR: [Errno 48] error while attempting to bind on address ('0.0.0.0', 8001): address already in use
```

The previous run's Python child processes (uvicorn servers) survived
diagrid's teardown and still hold ports 8001–8004. They have to be
SIGKILLed manually.

### Workaround

`./reset.sh` now greps for processes on the four server ports and
`kill -9`s them after stopping dev sessions:

```bash
for port in 8001 8002 8003 8004; do
    lsof -ti ":$port" | xargs kill -9
done
```

### Ask for engineering

`diagrid dev run` should send `SIGTERM`/`SIGKILL` to its entire process
group on shutdown (or use `setpgid` so a single signal reaches all
descendants). Today the wrapped command can survive a Ctrl+C, which
causes a port-already-in-use failure on the next start.

### Affected files in this repo
- `reset.sh`
