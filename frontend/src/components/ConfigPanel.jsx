// ConfigPanel.jsx
// Right-hand drawer shown when a node is selected. Renders inputs dynamically
// from that node type's `fields` schema in the catalog and writes changes back.

import { NODE_CATALOG, catColor } from "../pipeline/nodeCatalog";

function Field({ field, value, onChange }) {
  const base =
    "w-full rounded-lg border border-ink-500 bg-ink-900 px-3 py-2 font-mono text-[13px] " +
    "text-slate-100 outline-none focus:border-signal";

  if (field.kind === "select") {
    return (
      <select className={base} value={value ?? ""} onChange={(e) => onChange(e.target.value)}>
        {field.options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    );
  }
  if (field.kind === "toggle") {
    return (
      <button
        type="button"
        onClick={() => onChange(!value)}
        className={`relative h-6 w-11 rounded-full transition ${value ? "bg-signal" : "bg-ink-500"}`}
      >
        <span
          className={`absolute top-0.5 h-5 w-5 rounded-full bg-white transition ${
            value ? "left-[22px]" : "left-0.5"
          }`}
        />
      </button>
    );
  }
  return (
    <input
      className={base}
      value={value ?? ""}
      onChange={(e) => onChange(e.target.value)}
      placeholder={field.label}
    />
  );
}

export default function ConfigPanel({ node, onChange, onClose, onDelete }) {
  if (!node) return null;
  const spec = NODE_CATALOG[node.type] || NODE_CATALOG.checkout;
  const color = catColor(spec.category);
  const data = node.data || {};

  const setField = (key, val) => onChange(node.id, { ...data, [key]: val });

  const visibleFields = spec.fields.filter((f) => !f.showIf || f.showIf(data));

  return (
    <aside className="flex w-80 shrink-0 flex-col border-l border-ink-500 bg-ink-800">
      <div className="flex items-center justify-between border-b border-ink-500 px-4 py-3">
        <div className="flex items-center gap-2.5">
          <span
            className="grid h-7 w-7 place-items-center rounded-md font-mono text-sm"
            style={{ background: `${color}1a`, color }}
          >
            {spec.icon}
          </span>
          <span className="font-display text-sm font-700 text-slate-100">{spec.label}</span>
        </div>
        <button
          onClick={onClose}
          className="rounded-md px-2 py-1 font-mono text-xs text-slate-500 hover:bg-ink-600 hover:text-slate-200"
        >
          esc
        </button>
      </div>

      <div className="thin-scroll flex-1 space-y-4 overflow-y-auto p-4">
        {visibleFields.length === 0 && (
          <p className="font-mono text-[12px] text-slate-500">
            This step has no options. It runs as <span className="text-slate-300">{spec.blurb}</span>.
          </p>
        )}
        {visibleFields.map((field) => (
          <label key={field.key} className="block">
            <span className="mb-1.5 block font-mono text-[11px] uppercase tracking-wider text-slate-500">
              {field.label}
            </span>
            <Field field={field} value={data[field.key]} onChange={(v) => setField(field.key, v)} />
          </label>
        ))}
      </div>

      <div className="border-t border-ink-500 p-4">
        <button
          onClick={() => onDelete(node.id)}
          className="w-full rounded-lg border border-red-500/30 bg-red-500/10 py-2 font-mono text-[12px]
            text-red-300 transition hover:bg-red-500/20"
        >
          Delete step
        </button>
      </div>
    </aside>
  );
}