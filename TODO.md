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

## UI backend: replace `diagrid` CLI with REST calls

`ui_backend/main.py` shells out to `diagrid` for control-plane operations
(configuration get/update, appid get for tokens). Works but pulls a CLI
binary into the Docker image (`k8s/docker/ui-backend.Dockerfile`),
requires `DIAGRID_API_KEY` to be available to the pod shell, and
inherits the CLI's version cadence.

Replace `subprocess.run(["diagrid", ...])` with `httpx` calls against
`https://api.diagrid.io/...` using the same API key as a Bearer token.
Drops the CLI install from the image and removes one moving part.

## K8s: decide Catalyst Cloud connection model + finish wiring

`k8s/CATALYST.md` documents the trust model (Azure LB with
`loadBalancerSourceRanges` allowlisting Catalyst's egress IPs). The
`make register-appids` target uses a placeholder `--app-endpoint` flag
that needs verification against current diagrid CLI before first deploy.

Also: nginx-ingress variant of the chart for when a real domain is
available — Ingress per server, single LB, cert-manager TLS. Not wired;
documented as future-state in `k8s/CATALYST.md`.

## Remove unused backend routes (or keep as escape hatches)

`/api/policy/apply`, `/api/identity`, `/api/spoof` have no current UI
consumer after the UI rework that removed the Policy panel, Identity
drawer, and Adversarial scenarios row. They're kept for now as cheap
scripting/debugging surface. Decide whether to keep or drop in a follow-up.
