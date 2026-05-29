/* Result panel — DB state only.
   The HTTP Response + gate trace lives in the Agent Console now
   (paired with the call that produced it).
*/

function ResultPanel() {
  const [s] = window.__demo.useDemo();

  return (
    <section className="card" data-screen-label="Result">
      <div className="card-h">
        <div>
          <div className="eyebrow">02 · DB state</div>
          <h2>Employees · Postgres</h2>
        </div>
        <div className="sub">
          {s.employees.length} {s.employees.length === 1 ? "row" : "rows"}
        </div>
      </div>
      <div className="card-body" style={{ padding: 0 }}>
        <EmployeesTable employees={s.employees} rowFlash={s.rowFlash} />
      </div>
    </section>
  );
}

function EmployeesTable({ employees, rowFlash }) {
  return (
    <table className="emp-table">
      <thead>
        <tr>
          <th className="id">id</th>
          <th>name</th>
          <th>email</th>
          <th>department</th>
          <th style={{ textAlign: "right" }}>salary</th>
          <th>hired on</th>
        </tr>
      </thead>
      <tbody>
        {employees.map((e) => (
          <tr key={e.id} className={
            rowFlash && rowFlash.id === e.id
              ? (rowFlash.kind === "new" ? "new" : "out")
              : ""
          }>
            <td className="id">{e.id}</td>
            <td>{e.name}</td>
            <td>{e.email}</td>
            <td>{e.department || "—"}</td>
            <td style={{ textAlign: "right", fontVariantNumeric: "tabular-nums" }}>
              {fmtSalary(e.salary)}
            </td>
            <td style={{ fontVariantNumeric: "tabular-nums" }}>{e.hired_on || "—"}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function fmtSalary(s) {
  if (s == null) return "—";
  const n = Number(s);
  if (!isFinite(n)) return String(s);
  return "$" + n.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 0 });
}

window.ResultPanel = ResultPanel;
