// NodePalette.jsx — left sidebar. Drag a chip onto the canvas to add a node.

import { PALETTE, NODE_CATALOG, catColor } from "../pipeline/nodeCatalog";

export default function NodePalette() {
  const onDragStart = (e, type) => {
    e.dataTransfer.setData("application/pipeline-node", type);
    e.dataTransfer.effectAllowed = "move";
  };

  return (
    <aside className="flex w-56 shrink-0 flex-col border-r border-ink-500 bg-ink-800">
      <div className="border-b border-ink-500 px-4 py-3">
        <div className="font-mono text-[11px] uppercase tracking-[0.2em] text-slate-500">
          Steps
        </div>
        <p className="mt-1 text-[11px] leading-snug text-slate-500">
          Drag onto the canvas, then wire the handles together.
        </p>
      </div>

      <div className="thin-scroll flex flex-col gap-2 overflow-y-auto p-3">
        {PALETTE.map((type) => {
          const spec = NODE_CATALOG[type];
          const color = catColor(spec.category);
          return (
            <div
              key={type}
              draggable
              onDragStart={(e) => onDragStart(e, type)}
              className="flex cursor-grab items-center gap-3 rounded-lg border border-ink-500
                bg-ink-700 px-3 py-2.5 transition hover:border-signal/60 hover:bg-ink-600 active:cursor-grabbing"
            >
              <span
                className="grid h-7 w-7 place-items-center rounded-md font-mono text-sm"
                style={{ background: `${color}1a`, color }}
              >
                {spec.icon}
              </span>
              <span className="font-display text-[13px] font-600 text-slate-200">
                {spec.label}
              </span>
            </div>
          );
        })}
      </div>
    </aside>
  );
}
