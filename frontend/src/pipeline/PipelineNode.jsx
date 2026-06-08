// PipelineNode.jsx
// Custom React Flow node. Renders a compact "circuit module" card with a
// category accent stripe, the node's icon/label, and a one-line summary of its
// current config. Source/target handles let users wire steps together.

import { Handle, Position } from "@xyflow/react";
import { NODE_CATALOG, catColor } from "./nodeCatalog";

function summarize(type, data) {
  switch (type) {
    case "setup-node":
      return `node ${data.nodeVersion || "20"}`;
    case "install":
    case "build":
      return data.command || "";
    case "test":
      return data.framework || "playwright";
    case "deploy":
      return data.target || "vercel";
    default:
      return NODE_CATALOG[type]?.blurb || "";
  }
}

export default function PipelineNode({ type, data, selected }) {
  const spec = NODE_CATALOG[type] || NODE_CATALOG.checkout;
  const color = catColor(spec.category);

  return (
    <div
      className={`group relative w-[208px] rounded-xl bg-ink-700 shadow-node transition
        ${selected ? "ring-2 ring-signal" : "ring-1 ring-ink-500"}`}
    >
      {/* incoming handle (not on checkout, which is always the entry) */}
      {type !== "checkout" && (
        <Handle type="target" position={Position.Left} />
      )}

      {/* accent stripe */}
      <div
        className="absolute left-0 top-0 h-full w-1 rounded-l-xl"
        style={{ background: color }}
      />

      <div className="flex items-start gap-3 px-3.5 py-3 pl-4">
        <div
          className="grid h-8 w-8 shrink-0 place-items-center rounded-md font-mono text-[15px]"
          style={{ background: `${color}1a`, color }}
        >
          {spec.icon}
        </div>
        <div className="min-w-0">
          <div className="font-display text-[13.5px] font-700 leading-tight text-ink-100 text-slate-100">
            {spec.label}
          </div>
          <div className="mt-0.5 truncate font-mono text-[11px] text-slate-400">
            {summarize(type, data)}
          </div>
        </div>
      </div>

      <Handle type="source" position={Position.Right} />
    </div>
  );
}