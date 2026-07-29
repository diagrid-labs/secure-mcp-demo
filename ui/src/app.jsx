/* secure-mcp demo — root component */

function App() {
  return (
    <div className="app">
      <header className="chrome">
        <div className="brand">
          <img className="mark" src="assets/diagrid_brace.png" alt="" aria-hidden="true" />
          <img className="wordmark" src="assets/diagrid_wordmark.svg" alt="Diagrid" />
          <span className="crumb">MCP Access Demo</span>
        </div>
        <span className="spacer" />
        <span className="status" aria-label="event source connection">
          <span className="dot" />Connected to MCP Server
        </span>
      </header>

      <AgentConsole />
      <ResultPanel />
    </div>);

}

window.App = App;
ReactDOM.createRoot(document.getElementById("root")).render(<App />);