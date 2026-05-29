/* secure-mcp demo — root component */

function App() {
  return (
    <div className="app">
      <header className="chrome">
        <div className="brand">
          <img className="mark" src="assets/diagrid_brace.png" alt="" aria-hidden="true" />
          <img className="wordmark" src="assets/diagrid_wordmark.svg" alt="Diagrid" />
          <span className="crumb">secure-mcp · demo control</span>
        </div>
        <span className="spacer" />
        <span className="status" aria-label="event source connection">
          <span className="dot" />connected · event stream live
        </span>
      </header>

      <AgentConsole />
      <ResultPanel />

      <footer style={{
        marginTop: 24,
        font: "500 11px var(--font-mono)",
        letterSpacing: "0.10em",
        textTransform: "uppercase",
        color: "var(--neutral-400)",
        display: "flex", gap: 12, alignItems: "center"
      }}>
        <span>defense in depth · 3 gates</span>
        <span style={{ width: 4, height: 4, borderRadius: 999, background: "var(--neutral-300)" }} />
        <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
          <span style={{ width: 8, height: 8, borderRadius: 2, background: "var(--gate-edge-ring)" }} />
          app id
        </span>
        <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
          <span style={{ width: 8, height: 8, borderRadius: 2, background: "var(--gate-acl-ring)" }} />
          acl
        </span>
        <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
          <span style={{ width: 8, height: 8, borderRadius: 2, background: "var(--gate-jwt-ring)" }} />
          jwt
        </span>
        <span style={{ marginLeft: "auto" }}>diagrid · catalyst</span>
      </footer>
    </div>);

}

window.App = App;
ReactDOM.createRoot(document.getElementById("root")).render(<App />);