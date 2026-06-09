// KeyValueEditor.jsx — editable map. value: { [k]: v }
export default function KeyValueEditor({ value = {}, onChange, keyPlaceholder = "KEY", valPlaceholder = "value" }) {
  const rows = Object.entries(value);

  const setKey = (oldK, newK) => {
    const next = {};
    for (const [k, v] of rows) next[k === oldK ? newK : k] = v;
    onChange(next);
  };
  const setVal = (k, v) => onChange({ ...value, [k]: v });
  const remove = (k) => {
    const next = { ...value };
    delete next[k];
    onChange(next);
  };
  const add = () => {
    if (value[""] === undefined) onChange({ ...value, "": "" });
  };

  const inp =
    "rounded-md border border-ink-500 bg-ink-900 px-2 py-1.5 font-mono text-[12px] text-slate-100 outline-none focus:border-signal";

  return (
    <div className="space-y-1.5">
      {rows.map(([k, v], i) => (
        <div key={i} className="flex items-center gap-1.5">
          <input className={`${inp} w-2/5`} value={k} placeholder={keyPlaceholder}
            onChange={(e) => setKey(k, e.target.value)} />
          <span className="font-mono text-slate-600">=</span>
          <input className={`${inp} flex-1`} value={v} placeholder={valPlaceholder}
            onChange={(e) => setVal(k, e.target.value)} />
          <button onClick={() => remove(k)} className="px-1.5 text-slate-500 hover:text-red-300">✕</button>
        </div>
      ))}
      <button onClick={add} className="font-mono text-[11px] text-slate-400 hover:text-signal">
        + add pair
      </button>
    </div>
  );
}
