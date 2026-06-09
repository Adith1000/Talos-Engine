// App.jsx — pipeline builder shell.
// Layout:  [ palette ] [ canvas + toolbar ] [ dynamic config panel ]

import { useCallback, useMemo, useRef, useState } from "react";
import {
  ReactFlow,
  Background,
  BackgroundVariant,
  Controls,
  MiniMap,
  Panel,
  addEdge,
  useNodesState,
  useEdgesState,
  useReactFlow,
} from "@xyflow/react";

import NodePalette from "./components/NodePalette";
import ConfigPanel from "./components/ConfigPanel";
import SecretsModal from "./components/SecretsModal";
import PipelineNode from "./pipeline/PipelineNode";
import { NODE_CATALOG, catColor } from "./pipeline/nodeCatalog";
import { buildRunPayload, requiredSecrets } from "./pipeline/compilePayload";
import { compilePreview, runPipeline } from "./api";

let idSeq = 100;
const nextId = () => `n${idSeq++}`;
const d = (type) => structuredClone(NODE_CATALOG[type].defaults);

const INITIAL_NODES = [
  { id: "wf", type: "workflow", position: { x: 20, y: 40 }, data: { name: "CI Pipeline" } },
  { id: "ev", type: "event", position: { x: 20, y: 180 }, data: d("event") },
  { id: "jb", type: "job", position: { x: 300, y: 110 }, data: d("job") },
  { id: "a1", type: "action", position: { x: 560, y: 30 }, data: { ...d("action"), action: "actions/checkout@v4" } },
  { id: "a2", type: "action", position: { x: 560, y: 150 }, data: { ...d("action"), action: "actions/setup-node@v4", withArgs: { "node-version": "20", cache: "npm" } } },
  { id: "st", type: "step", position: { x: 820, y: 90 }, data: { ...d("step"), name: "Install", run: "npm ci" } },
  { id: "ts", type: "testsuite", position: { x: 1080, y: 90 }, data: { framework: "playwright", testcases: [{ title: "Home loads", route: "/", assertion: "contains_text", expected: "Welcome" }] } },
];
const INITIAL_EDGES = [
  { id: "e1", source: "jb", target: "a1" },
  { id: "e2", source: "a1", target: "a2" },
  { id: "e3", source: "a2", target: "st" },
  { id: "e4", source: "st", target: "ts" },
];

export default function App() {
  const wrapper = useRef(null);
  const { screenToFlowPosition } = useReactFlow();

  const [nodes, setNodes, onNodesChange] = useNodesState(INITIAL_NODES);
  const [edges, setEdges, onEdgesChange] = useEdgesState(INITIAL_EDGES);
  const [selectedId, setSelectedId] = useState(null);

  const [repoUrl, setRepoUrl] = useState("");
  const [token, setToken] = useState("");
  const [branch, setBranch] = useState("main");

  const [secrets, setSecrets] = useState({});
  const [secretsOpen, setSecretsOpen] = useState(false);

  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState(null);

  const nodeTypes = useMemo(
    () => Object.fromEntries(Object.keys(NODE_CATALOG).map((t) => [t, PipelineNode])),
    []
  );

  const selectedNode = nodes.find((n) => n.id === selectedId) || null;
  const neededSecrets = useMemo(() => requiredSecrets(nodes), [nodes]);

  const onConnect = useCallback(
    (c) => setEdges((eds) => addEdge({ ...c, id: `e${nextId()}` }, eds)),
    [setEdges]
  );

  const onDrop = useCallback(
    (event) => {
      event.preventDefault();
      const type = event.dataTransfer.getData("application/pipeline-node");
      if (!type || !NODE_CATALOG[type]) return;
      const position = screenToFlowPosition({ x: event.clientX, y: event.clientY });
      setNodes((nds) => nds.concat({ id: nextId(), type, position, data: d(type) }));
    },
    [screenToFlowPosition, setNodes]
  );
  const onDragOver = useCallback((e) => {
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
  }, []);

  const updateNodeData = useCallback(
    (id, data) => setNodes((nds) => nds.map((n) => (n.id === id ? { ...n, data } : n))),
    [setNodes]
  );
  const deleteNode = useCallback(
    (id) => {
      setNodes((nds) => nds.filter((n) => n.id !== id));
      setEdges((eds) => eds.filter((e) => e.source !== id && e.target !== id));
      setSelectedId(null);
    },
    [setNodes, setEdges]
  );

  const validate = () => {
    if (!repoUrl.startsWith("https://github.com/")) return "Repo URL must start with https://github.com/";
    if (!token.trim()) return "An access token is required";
    if (!nodes.length) return "Add at least one node";
    return null;
  };

  const doPreview = async () => {
    setBusy(true);
    setResult(null);
    try {
      const payload = buildRunPayload({ nodes, edges, repoUrl: repoUrl || "https://github.com/x/y", token: token || "x", branch, secrets });
      const { compiled_yaml, spec_files } = await compilePreview(payload);
      setResult({ yaml: compiled_yaml, specs: spec_files });
    } catch (e) {
      setResult({ error: e.message });
    } finally {
      setBusy(false);
    }
  };

  const doRun = async () => {
    const err = validate();
    if (err) return setResult({ error: err });
    setBusy(true);
    setResult(null);
    try {
      const res = await runPipeline(buildRunPayload({ nodes, edges, repoUrl, token, branch, secrets }));
      setResult({ yaml: res.compiled_yaml, specs: (res.spec_files || []).map((p) => ({ path: p })), logs: res.logs, written: res.secrets_written });
    } catch (e) {
      setResult({ error: e.message });
    } finally {
      setBusy(false);
    }
  };

  const inputCls =
    "rounded-lg border border-ink-500 bg-ink-900 px-3 py-1.5 font-mono text-[12px] text-slate-100 outline-none focus:border-signal";

  return (
    <div className="flex h-screen flex-col bg-ink-900 text-slate-200">
      <header className="flex items-center gap-4 border-b border-ink-500 bg-ink-800 px-5 py-3">
        <div className="flex items-center gap-2.5">
          <div className="grid h-7 w-7 place-items-center rounded-md bg-signal font-mono text-sm font-700 text-ink-900">⌗</div>
          <span className="font-display text-[15px] font-800 tracking-tight text-slate-100">
            Pipeline<span className="text-signal">Builder</span>
          </span>
        </div>
        <div className="ml-4 flex flex-1 items-center gap-2">
          <input className={`${inputCls} flex-1`} placeholder="https://github.com/owner/repo" value={repoUrl} onChange={(e) => setRepoUrl(e.target.value)} />
          <input className={`${inputCls} w-44`} type="password" placeholder="access token" value={token} onChange={(e) => setToken(e.target.value)} />
          <input className={`${inputCls} w-24`} placeholder="branch" value={branch} onChange={(e) => setBranch(e.target.value)} />
        </div>
        <button onClick={() => setSecretsOpen(true)} className="rounded-lg border border-ink-500 bg-ink-700 px-3 py-1.5 font-mono text-[12px] text-slate-300 hover:bg-ink-600">
          Secrets
          {neededSecrets.length > 0 && (
            <span className="ml-2 rounded bg-signal/15 px-1.5 text-[10px] text-signal-soft">
              {Object.keys(secrets).filter((k) => secrets[k]).length}/{neededSecrets.length}
            </span>
          )}
        </button>
        <button onClick={doPreview} disabled={busy} className="rounded-lg border border-ink-500 bg-ink-700 px-3 py-1.5 font-mono text-[12px] text-slate-300 hover:bg-ink-600 disabled:opacity-50">
          Preview YAML
        </button>
        <button onClick={doRun} disabled={busy} className="rounded-lg bg-signal px-4 py-1.5 font-mono text-[12px] font-700 text-ink-900 hover:bg-signal-soft disabled:opacity-50">
          {busy ? "Running…" : "▶ Run"}
        </button>
      </header>

      <div className="flex min-h-0 flex-1">
        <NodePalette />
        <div className="relative min-w-0 flex-1" ref={wrapper} onDrop={onDrop} onDragOver={onDragOver}>
          <ReactFlow
            nodes={nodes}
            edges={edges}
            nodeTypes={nodeTypes}
            onNodesChange={onNodesChange}
            onEdgesChange={onEdgesChange}
            onConnect={onConnect}
            onNodeClick={(_, n) => setSelectedId(n.id)}
            onPaneClick={() => setSelectedId(null)}
            fitView
            defaultEdgeOptions={{ type: "smoothstep", animated: true }}
          >
            <Background variant={BackgroundVariant.Dots} gap={22} size={1} color="#1d222b" />
            <Controls position="bottom-left" />
            <MiniMap pannable zoomable nodeColor={(n) => catColor(NODE_CATALOG[n.type]?.category)} maskColor="rgba(10,12,16,0.7)" />
            {result && (
              <Panel position="top-right" className="m-3">
                <ResultCard result={result} onClose={() => setResult(null)} />
              </Panel>
            )}
          </ReactFlow>
        </div>
        <ConfigPanel node={selectedNode} allNodes={nodes} onChange={updateNodeData} onClose={() => setSelectedId(null)} onDelete={deleteNode} />
      </div>

      <SecretsModal
        open={secretsOpen}
        secrets={secrets}
        required={neededSecrets}
        onSave={(s) => { setSecrets(s); setSecretsOpen(false); }}
        onClose={() => setSecretsOpen(false)}
      />
    </div>
  );
}

function ResultCard({ result, onClose }) {
  return (
    <div className="w-[440px] max-w-[80vw] overflow-hidden rounded-xl border border-ink-500 bg-ink-800/95 shadow-node backdrop-blur">
      <div className="flex items-center justify-between border-b border-ink-500 px-4 py-2.5">
        <span className="font-mono text-[11px] uppercase tracking-wider text-slate-400">
          {result.error ? "Error" : result.logs ? "Run complete" : "Compiled output"}
        </span>
        <button onClick={onClose} className="font-mono text-xs text-slate-500 hover:text-slate-200">✕</button>
      </div>
      <div className="thin-scroll max-h-[62vh] overflow-auto p-3">
        {result.error ? (
          <pre className="whitespace-pre-wrap font-mono text-[11.5px] text-red-300">{result.error}</pre>
        ) : (
          <>
            {result.written?.length > 0 && (
              <p className="mb-2 font-mono text-[11px] text-cat-deploy" style={{ color: "#34d399" }}>
                secrets set: {result.written.join(", ")}
              </p>
            )}
            {result.specs?.length > 0 && (
              <p className="mb-2 font-mono text-[11px] text-slate-400">
                spec files: {result.specs.map((s) => s.path).join(", ")}
              </p>
            )}
            <pre className="whitespace-pre-wrap font-mono text-[11.5px] leading-relaxed text-slate-300">{result.yaml}</pre>
            {result.logs && (
              <pre className="mt-3 whitespace-pre-wrap border-t border-ink-500 pt-3 font-mono text-[11px] text-slate-400">{result.logs}</pre>
            )}
          </>
        )}
      </div>
    </div>
  );
}
