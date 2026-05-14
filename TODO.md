# TODO

## Revisit auto-advance for `run_demo.sh`

Our earlier attempts at auto-teardown between agents (`pkill -INT`,
`diagrid dev stop`) produced 502s on calls that should have passed. We
concluded the cascade was inherent and moved to a Ctrl+C-between-agents
workflow.

Caveat we only realized later: those tests ran on **dirty Catalyst state**
left over from prior broken sessions — the 502s may have been pre-existing
damage rather than a fresh symptom of the teardown method.

When time permits, retest from a known-clean slate:

1. `diagrid dev stop --app-id <X>` for every app-id in the project
2. `diagrid dev status` confirms zero active sessions
3. Restart server-side `diagrid dev run -f dev.yaml`
4. Try the `diagrid dev stop` auto-teardown variant of `run_demo.sh` —
   does it now advance cleanly without 502s on the next role?

If yes → auto-advance is viable; swap back in for a hands-off scripted
flow. If no → file the structural-cascade bug with diagrid eng (see
`KNOWN_ISSUES.md`).

The Ctrl+C workflow is fine for live demos (narration pauses fit), so
this is backlog, not blocking.

## Build a keepalive script if idle-disconnect bites during rehearsal

Server-side tunnels from `diagrid dev run -f dev.yaml` go stale after
extended idle (~20+ min observed). `diagrid dev status` still reports
"ready" — misleading. Symptom: every allowed call returns HTTP 502;
denied calls still 403 correctly (ACL runs at the edge, before the
tunnel).

Recovery today: Ctrl+C terminal 1, `./reset.sh`, restart dev.yaml.
Acceptable for live demo (no idle gap during recording), painful for
rehearsal.

If/when it bites during rehearsal, build `scripts/keepalive.sh`:
- Loops every 30s
- For each `mcp-db-{schema,query,write,ddl}`, sends an MCP `initialize`
  through Catalyst using any agent's token (admin-agent is easy — has
  access everywhere)
- Background process — user starts when they begin rehearsing, kills
  when done
- Prints `(refreshed)` once per loop so it's visibly alive

Also worth filing with diagrid eng: `diagrid dev status` should reflect
tunnel liveness, not just session existence. And ideally tunnels should
self-restore or be kept warm by the CLI itself.
