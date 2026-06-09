// ConfigPanel.jsx
// The interactive sidebar editor. It reads the selected node's type, pulls that
// type's `fields` schema from the catalog, and renders the right widget for each
// field kind — writing every change straight back into the node's data state.
//
// `allNodes` is needed so the Job node's "needs" can list the other jobs.

import {
  NODE_CATALOG,
  catColor,
  ACTION_SCHEMAS,
} from "../pipeline/nodeCatalog";
import ChipsInput from "./editors/ChipsInput";
import KeyValueEditor from "./editors/KeyValueEditor";
import MultiSelect from "./editors/MultiSelect";
import TestcaseManager from "./editors/TestcaseManager";

const baseInput =
  "w-full rounded-lg border border-ink-500 bg-ink-900 px-3 py-2 font-mono text-[13px] text-slate-100 outline-none focus:border-signal";

function Field({ field, data, value, onChange, allNodes }) {
  switch (field.kind) {
    case "select":
      return (
        <select className={baseInput} value={value ?? ""} onChange={(e) => onChange(e.target.value)}>
          {field.options.map((o) => (
            <option key={o.value} value={o.value}>{o.label}</option>
          ))}
        </select>
      );

    case "number":
      return (
        <input
          type="number"
          className={baseInput}
          value={value ?? ""}
          placeholder={field.placeholder}
          onChange={(e) => onChange(e.target.value === "" ? null : Number(e.target.value))}
        />
      );

    case "textarea":
      return (
        <textarea
          rows={3}
          className={`${baseInput} resize-y`}
          value={value ?? ""}
          placeholder={field.placeholder}
          onChange={(e) => onChange(e.target.value)}
        />
      );

    case "toggle":
      return (
        <button
          type="button"
          onClick={() => onChange(!value)}
          className={`relative h-6 w-11 rounded-full transition ${value ? "bg-signal" : "bg-ink-500"}`}
        >
          <span className={`absolute top-0.5 h-5 w-5 rounded-full bg-white transition ${value ? "left-[22px]" : "left-0.5"}`} />
        </button>
      );

    case "multiselect":
      return <MultiSelect value={value ?? []} options={field.options} onChange={onChange} />;

    case "chips":
      return <ChipsInput value={value ?? []} onChange={onChange} placeholder={field.placeholder || "add…"} />;

    case "secretlist":
      return (
        <ChipsInput
          value={value ?? []}
          onChange={(arr) => onChange(arr.map((s) => s.toUpperCase()))}
          placeholder="SECRET_NAME"
        />
      );

    case "keyvalue":
      return <KeyValueEditor value={value ?? {}} onChange={onChange} />;

    case "testcases":
      return <TestcaseManager value={value ?? []} onChange={onChange} />;

    case "jobNeeds": {
      const jobOptions = (allNodes || [])
        .filter((n) => n.type === "job")
        .map((n) => n.data?.jobId)
        .filter(Boolean)
        .filter((id) => id !== data.jobId)
        .map((id) => ({ value: id, label: id }));
      if (jobOptions.length === 0)
        return <p className="font-mono text-[12px] text-slate-500">No other jobs to depend on yet.</p>;
      return <MultiSelect value={value ?? []} options={jobOptions} onChange={onChange} />;
    }

    case "actionWith": {
      const schema = ACTION_SCHEMAS[data.action] || [];
      const args = value ?? {};
      if (schema.length === 0)
        return <p className="font-mono text-[12px] text-slate-500">This action takes no inputs.</p>;
      return (
        <div className="space-y-1.5">
          {schema.map((arg) => (
            <div key={arg.key} className="flex items-center gap-2">
              <span className="w-1/3 font-mono text-[11px] text-slate-400">{arg.label}</span>
              <input
                className="flex-1 rounded-md border border-ink-500 bg-ink-900 px-2 py-1.5 font-mono text-[12px] text-slate-100 outline-none focus:border-signal"
                value={args[arg.key] ?? ""}
                onChange={(e) => onChange({ ...args, [arg.key]: e.target.value })}
              />
            </div>
          ))}
        </div>
      );
    }

    default: // text
      return (
        <input
          className={baseInput}
          value={value ?? ""}
          placeholder={field.placeholder}
          onChange={(e) => onChange(e.target.value)}
        />
      );
  }
}

export default function ConfigPanel({ node, allNodes, onChange, onClose, onDelete }) {
  if (!node) {
    return (
      <aside className="flex w-80 shrink-0 flex-col items-center justify-center border-l border-ink-500 bg-ink-800 px-6 text-center">
        <p className="font-mono text-[12px] leading-relaxed text-slate-500">
          Select a node to configure it.
          <br />
          Drag steps from the left and wire their handles.
        </p>
      </aside>
    );
  }

  const spec = NODE_CATALOG[node.type];
  const color = catColor(spec.category);
  const data = node.data || {};
  const setField = (key, val) => onChange(node.id, { ...data, [key]: val });
  const visible = spec.fields.filter((f) => !f.showIf || f.showIf(data));

  return (
    <aside className="flex w-80 shrink-0 flex-col border-l border-ink-500 bg-ink-800">
      <div className="flex items-center justify-between border-b border-ink-500 px-4 py-3">
        <div className="flex items-center gap-2.5">
          <span className="grid h-7 w-7 place-items-center rounded-md font-mono text-sm" style={{ background: `${color}1a`, color }}>
            {spec.icon}
          </span>
          <div>
            <div className="font-display text-sm font-700 text-slate-100">{spec.label}</div>
            <div className="font-mono text-[10px] text-slate-500">{node.type}</div>
          </div>
        </div>
        <button onClick={onClose} className="rounded-md px-2 py-1 font-mono text-xs text-slate-500 hover:bg-ink-600 hover:text-slate-200">
          esc
        </button>
      </div>

      <div className="thin-scroll flex-1 space-y-4 overflow-y-auto p-4">
        {visible.map((field) => (
          <label key={field.key} className="block">
            <span className="mb-1.5 block font-mono text-[11px] uppercase tracking-wider text-slate-500">
              {field.label}
            </span>
            <Field
              field={field}
              data={data}
              value={data[field.key]}
              onChange={(v) => setField(field.key, v)}
              allNodes={allNodes}
            />
          </label>
        ))}
      </div>

      <div className="border-t border-ink-500 p-4">
        <button
          onClick={() => onDelete(node.id)}
          className="w-full rounded-lg border border-red-500/30 bg-red-500/10 py-2 font-mono text-[12px] text-red-300 transition hover:bg-red-500/20"
        >
          Delete node
        </button>
      </div>
    </aside>
  );
}
