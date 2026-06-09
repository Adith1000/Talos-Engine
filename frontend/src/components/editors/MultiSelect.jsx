// MultiSelect.jsx — checkbox group. value: string[]
export default function MultiSelect({ value = [], options = [], onChange }) {
  const toggle = (v) =>
    onChange(value.includes(v) ? value.filter((x) => x !== v) : [...value, v]);

  return (
    <div className="grid grid-cols-2 gap-1.5">
      {options.map((o) => {
        const on = value.includes(o.value);
        return (
          <button
            key={o.value}
            onClick={() => toggle(o.value)}
            className={`flex items-center gap-2 rounded-lg border px-2.5 py-1.5 text-left font-mono text-[12px] transition
              ${on
                ? "border-signal/60 bg-signal/10 text-signal-soft"
                : "border-ink-500 bg-ink-900 text-slate-300 hover:bg-ink-600"}`}
          >
            <span
              className={`grid h-3.5 w-3.5 place-items-center rounded-[3px] border text-[9px]
                ${on ? "border-signal bg-signal text-ink-900" : "border-ink-500"}`}
            >
              {on ? "✓" : ""}
            </span>
            {o.label}
          </button>
        );
      })}
    </div>
  );
}
