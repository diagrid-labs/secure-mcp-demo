/* Shared little components */

function RoleGlyph({ role }) {
  const initials = { analyst: "AN", ops: "OP", admin: "AD" };
  return <span className="role-glyph">{initials[role]}</span>;
}

function GateChip({ which, state = "passed", label }) {
  // which: "edge" | "acl" | "jwt"
  // state: "passed" | "failed" | "neutral"
  const names = { edge: "Catalyst edge", acl: "Catalyst ACL", jwt: "JWT middleware" };
  return (
    <span className={`gate-chip ${which} ${state}`} style={{
      display: "inline-flex", alignItems: "center", gap: 6,
      padding: "4px 10px", borderRadius: 999,
      font: "500 12px var(--font-mono)",
      letterSpacing: "0.04em",
      background: state === "passed" ? "var(--ok-bg)" :
                  state === "failed" ? "var(--fail-bg)" :
                  `var(--gate-${which}-bg)`,
      color: state === "passed" ? "var(--ok-fg)" :
             state === "failed" ? "var(--fail-fg)" :
             `var(--gate-${which})`,
      border: state === "neutral" ? `1px solid var(--gate-${which}-ring)` : "1px solid transparent",
    }}>
      <span style={{
        width: 6, height: 6, borderRadius: 999,
        background: state === "passed" ? "var(--green-500)" :
                    state === "failed" ? "var(--red-500)" :
                    `var(--gate-${which}-ring)`
      }} />
      {label || names[which]}
    </span>
  );
}

window.RoleGlyph = RoleGlyph;
window.GateChip = GateChip;
