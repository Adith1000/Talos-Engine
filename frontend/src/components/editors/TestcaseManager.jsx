// TestcaseManager.jsx — interactive list of testcases. value: TestCase[]
import { ASSERTIONS } from "../../pipeline/nodeCatalog";

const blank = () => ({ title: "", route: "/", assertion: "contains_text", expected: "" });

export default function TestcaseManager({ value = [], onChange }) {
  const update = (i, patch) =>
    onChange(value.map((tc, idx) => (idx === i ? { ...tc, ...patch } : tc)));
  const remove = (i) => onChange(value.filter((_, idx) => idx !== i));
  const add = () => onChange([...value, blank()]);

  const inp =
    "w-full rounded-md border border-ink-500 bg-ink-900 px-2 py-1.5 font-mono text-[12px] text-slate-100 outline-none focus:border-signal";
  const lbl = "mb-1 block font-mono text-[10px] uppercase tracking-wider text-slate-500";

  return (
    <div className="space-y-2.5">
      {value.map((tc, i) => (
        <div key={i} className="rounded-lg border border-ink-500 bg-ink-700/60 p-2.5">
          <div className="mb-2 flex items-center justify-between">
            <span className="font-mono text-[10px] text-slate-500">#{i + 1}</span>
            <button onClick={() => remove(i)} className="font-mono text-[11px] text-slate-500 hover:text-red-300">
              remove
            </button>
          </div>

          <label className={lbl}>Title</label>
          <input className={inp} value={tc.title} placeholder="Login page loads"
            onChange={(e) => update(i, { title: e.target.value })} />

          <div className="mt-2 grid grid-cols-2 gap-2">
            <div>
              <label className={lbl}>Route</label>
              <input className={inp} value={tc.route} placeholder="/login"
                onChange={(e) => update(i, { route: e.target.value })} />
            </div>
            <div>
              <label className={lbl}>Assertion</label>
              <select className={inp} value={tc.assertion}
                onChange={(e) => update(i, { assertion: e.target.value })}>
                {ASSERTIONS.map((a) => (
                  <option key={a.value} value={a.value}>{a.label}</option>
                ))}
              </select>
            </div>
          </div>

          <label className={`${lbl} mt-2`}>
            {tc.assertion === "element_visible" ? "Selector" :
             tc.assertion === "status_code" ? "Status code" :
             tc.assertion === "url_contains" ? "URL fragment" : "Expected text"}
          </label>
          <input className={inp} value={tc.expected}
            placeholder={tc.assertion === "status_code" ? "200" : tc.assertion === "element_visible" ? "#app" : "Sign in"}
            onChange={(e) => update(i, { expected: e.target.value })} />
        </div>
      ))}

      <button
        onClick={add}
        className="w-full rounded-lg border border-dashed border-ink-500 py-2 font-mono text-[12px] text-slate-400 hover:border-signal/60 hover:text-signal"
      >
        + Add testcase
      </button>
    </div>
  );
}
