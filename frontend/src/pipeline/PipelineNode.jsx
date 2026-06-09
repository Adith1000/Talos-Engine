// PipelineNode.jsx — custom React Flow node for all 8 types.
import { Handle, Position } from "@xyflow/react";
import { NODE_CATALOG, catColor } from "./nodeCatalog";

function summarize(type, d = {}) {
  switch (type) {
    case "workflow": return d.name || "CI Pipeline";
    case "event": return (d.triggers || []).join(", ") || "no triggers";
    case "job": return `${d.jobId || "job"} · ${d.runsOn || "ubuntu"}`;
    case "runner": return d.hosted ? d.image || "hosted" : `self-hosted ${(d.labels || []).join(",")}`;
    case "step": return d.mode === "uses" ? d.uses || "uses…" : (d.run || "run…").split("\n")[0];
    case "action": return d.action || "action";
    case "secrets": return `${(d.secrets || []).length} secret(s), ${Object.keys(d.vars || {}).length} var(s)`;
    case "testsuite": return `${d.framework || "playwright"} · ${(d.testcases || []).length} case(s)`;
    default: return NODE_CATALOG[type]?.blurb || "";
  }
}

export default function PipelineNode({ type, data, selected }) {
  const spec = NODE_CATALOG[type] || NODE_CATALOG.step;
  const color = catColor(spec.category);
  // workflow + event are "global"/root-ish; they still expose handles so they
  // can be wired, but workflow has no incoming handle.
  const hasTarget = type !== "workflow";

  return (
    <div
      className={`group relative w-[214px] rounded-xl bg-ink-700 shadow-node transition
        ${selected ? "ring-2 ring-signal" : "ring-1 ring-ink-500"}`}
    >
      {hasTarget && <Handle type="target" position={Position.Left} />}
      <div className="absolute left-0 top-0 h-full w-1 rounded-l-xl" style={{ background: color }} />

      <div className="flex items-start gap-3 px-3.5 py-3 pl-4">
        <div
          className="grid h-8 w-8 shrink-0 place-items-center rounded-md font-mono text-[15px]"
          style={{ background: `${color}1a`, color }}
        >
          {spec.icon}
        </div>
        <div className="min-w-0">
          <div className="font-display text-[13.5px] font-700 leading-tight text-slate-100">
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
