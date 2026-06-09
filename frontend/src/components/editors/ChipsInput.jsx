// ChipsInput.jsx — comma/Enter to add, click ✕ to remove. value: string[]
import { useState } from "react";

export default function ChipsInput({ value = [], onChange, placeholder = "type & Enter" }) {
  const [draft, setDraft] = useState("");

  const add = (raw) => {
    const v = raw.trim().replace(/,$/, "");
    if (v && !value.includes(v)) onChange([...value, v]);
    setDraft("");
  };
  const remove = (v) => onChange(value.filter((x) => x !== v));

  return (
    <div className="flex flex-wrap items-center gap-1.5 rounded-lg border border-ink-500 bg-ink-900 p-1.5">
      {value.map((v) => (
        <span
          key={v}
          className="flex items-center gap-1 rounded-md bg-ink-600 px-2 py-1 font-mono text-[11px] text-slate-200"
        >
          {v}
          <button onClick={() => remove(v)} className="text-slate-500 hover:text-red-300">
            ✕
          </button>
        </span>
      ))}
      <input
        className="min-w-[80px] flex-1 bg-transparent px-1 py-0.5 font-mono text-[12px] text-slate-100 outline-none"
        value={draft}
        placeholder={value.length ? "" : placeholder}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === ",") {
            e.preventDefault();
            add(draft);
          } else if (e.key === "Backspace" && !draft && value.length) {
            remove(value[value.length - 1]);
          }
        }}
        onBlur={() => draft && add(draft)}
      />
    </div>
  );
}
