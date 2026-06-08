// App.jsx — the pipeline builder shell.
//
// Layout:  [ palette ] [ canvas + toolbar ] [ config panel ]
// Toolbar holds repo URL / token / branch, Secrets, Preview YAML, and Run.

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

// A sensible starting pipeline
const INITIAL_NODES = [
  { id: "n1", type: "checkout", position: { x: 40, y: 120 }, data: { ...NODE_CATALOG.checkout.defaults } },
  { id: "n2", type: "setup-node", position: { x: 300, y: 120 }, data: { ...NODE_CATALOG["setup-node"].defaults } },
  { id: "n3", type: "install", position: { x: 560, y: 120 }, data: { ...NODE_CATALOG.install.defaults } },
  { id: "n4", type: "test", position: { x: 820, y: 120 }, data: { ...NODE_CATALOG.test.defaults } },
  { id: "n5", type: "deploy", position: { x: 1080, y: 120 }, data: { ...NODE_CATALOG.deploy.defaults } },
];
const INITIAL_EDGES = [
  { id: "e1", source: "n1", target: "n2" },
  { id: "e2", source: "n2", target: "n3" },
  { id: "e3", source: "n3", target: "n4" },
  { id: "e4", source: "n4", target: "n5" },
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
  const [result, setResult] = useState(null); // { yaml, logs, error, written }

  const nodeTypes = useMemo(
    () => Object.fromEntries(Object.keys(NODE_CATALOG).map((t) => [t, PipelineNode])),
    []
  );

  const selectedNode = nodes.find((n) => n.id === selectedId) || null;
  const neededSecrets = useMemo(() => requiredSecrets(nodes), [nodes]);

  // ── graph editing ──────────────────────────────────────────────────────
  const onConnect = useCallback(
    (conn) => setEdges((eds) => addEdge({ ...conn, id: `e${nextId()}` }, eds)),
    [setEdges]
  );

  const onDrop = useCallback(
    (event) => {
      event.preventDefault();
      const type = event.dataTransfer.getData("application/pipeline-node");
      if (!type || !NODE_CATALOG[type]) return;
      const position = screenToFlowPosition({ x: event.clientX, y: event.clientY });
      const id = nextId();
      setNodes((nds) =>
        nds.concat({ id, type, position, data: { ...NODE_CATALOG[type].defaults } })
      );
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

  // ── backend actions ────────────────────────────────────────────────────
  const validate = () => {
    if (!repoUrl.startsWith("https://github.com/")) return "Repo URL must start with https://github.com/";
    if (!token.trim()) return "An access token is required";
    if (nodes.length === 0) return "Add at least one step";
    return null;
  };

  const doPreview = async () => {
    const payload = buildRunPayload({ nodes, edges, repoUrl: repoUrl || "https://github.com/x/y", token: token || "x", branch, secrets });
    setBusy(true);
    setResult(null);
    try {
      const { compiled_yaml } = await compilePreview(payload);
      setResult({ yaml: compiled_yaml });
    } catch (e) {
      setResult({ error: e.message });
    } finally {
      setBusy(false);
    }
  };

  const doRun = async () => {
    const err = validate();
    if (err) {
      setResult({ error: err });
      return;
    }
    const payload = buildRunPayload({ nodes, edges, repoUrl, token, branch, secrets });
    setBusy(true);
    setResult(null);
    try {
      const res = await runPipeline(payload);
      setResult({ yaml: res.compiled_yaml, logs: res.logs, written: res.secrets_written });
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
      {/* top bar */}
      <header className="flex items-center gap-4 border-b border-ink-500 bg-ink-800 px-5 py-3">
        <div className="flex items-center gap-2.5">
          <div className="grid h-7 w-7 place-items-center rounded-md bg-signal font-mono text-sm font-700 text-ink-900">
            ⌗
          </div>
          <span className="font-display text-[15px] font-800 tracking-tight text-slate-100">
            Pipeline<span className="text-signal">Builder</span>
          </span>
        </div>

        <div className="ml-4 flex flex-1 items-center gap-2">
          <input
            className={`${inputCls} flex-1`}
            placeholder="https://github.com/owner/repo"
            value={repoUrl}
            onChange={(e) => setRepoUrl(e.target.value)}
          />
          <input
            className={`${inputCls} w-44`}
            type="password"
            placeholder="access token"
            value={token}
            onChange={(e) => setToken(e.target.value)}
          />
          <input
            className={`${inputCls} w-24`}
            placeholder="branch"
            value={branch}
            onChange={(e) => setBranch(e.target.value)}
          />
        </div>

        <button
          onClick={() => setSecretsOpen(true)}
          className="relative rounded-lg border border-ink-500 bg-ink-700 px-3 py-1.5 font-mono text-[12px] text-slate-300 hover:bg-ink-600"
        >
          Secrets
          {neededSecrets.length > 0 && (
            <span className="ml-2 rounded bg-signal/15 px-1.5 text-[10px] text-signal-soft">
              {Object.keys(secrets).filter((k) => secrets[k]).length}/{neededSecrets.length}
            </span>
          )}
        </button>
        <button
          onClick={doPreview}
          disabled={busy}
          className="rounded-lg border border-ink-500 bg-ink-700 px-3 py-1.5 font-mono text-[12px] text-slate-300 hover:bg-ink-600 disabled:opacity-50"
        >
          Preview YAML
        </button>
        <button
          onClick={doRun}
          disabled={busy}
          className="rounded-lg bg-signal px-4 py-1.5 font-mono text-[12px] font-700 text-ink-900 hover:bg-signal-soft disabled:opacity-50"
        >
          {busy ? "Running…" : "▶ Run"}
        </button>
      </header>

      {/* body */}
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
            proOptions={{ hideAttribution: false }}
            defaultEdgeOptions={{ type: "smoothstep", animated: true }}
          >
            <Background variant={BackgroundVariant.Dots} gap={22} size={1} color="#1d222b" />
            <Controls position="bottom-left" />
            <MiniMap
              pannable
              zoomable
              nodeColor={(n) => catColor(NODE_CATALOG[n.type]?.category)}
              maskColor="rgba(10,12,16,0.7)"
            />

            {/* results overlay */}
            {result && (
              <Panel position="top-right" className="m-3">
                <ResultCard result={result} onClose={() => setResult(null)} />
              </Panel>
            )}
          </ReactFlow>
        </div>

        <ConfigPanel
          node={selectedNode}
          onChange={updateNodeData}
          onClose={() => setSelectedId(null)}
          onDelete={deleteNode}
        />
      </div>

      <SecretsModal
        open={secretsOpen}
        secrets={secrets}
        required={neededSecrets}
        onSave={(s) => {
          setSecrets(s);
          setSecretsOpen(false);
        }}
        onClose={() => setSecretsOpen(false)}
      />
    </div>
  );
}

function ResultCard({ result, onClose }) {
  return (
    <div className="w-[420px] max-w-[80vw] overflow-hidden rounded-xl border border-ink-500 bg-ink-800/95 shadow-node backdrop-blur">
      <div className="flex items-center justify-between border-b border-ink-500 px-4 py-2.5">
        <span className="font-mono text-[11px] uppercase tracking-wider text-slate-400">
          {result.error ? "Error" : result.logs ? "Run complete" : "Compiled YAML"}
        </span>
        <button onClick={onClose} className="font-mono text-xs text-slate-500 hover:text-slate-200">
          ✕
        </button>
      </div>
      <div className="thin-scroll max-h-[60vh] overflow-auto p-3">
        {result.error ? (
          <pre className="whitespace-pre-wrap font-mono text-[11.5px] text-red-300">{result.error}</pre>
        ) : (
          <>
            {result.written?.length > 0 && (
              <p className="mb-2 font-mono text-[11px] text-cat-deploy">
                secrets set: {result.written.join(", ")}
              </p>
            )}
            <pre className="whitespace-pre-wrap font-mono text-[11.5px] leading-relaxed text-slate-300">
              {result.yaml}
            </pre>
            {result.logs && (
              <pre className="mt-3 whitespace-pre-wrap border-t border-ink-500 pt-3 font-mono text-[11px] text-slate-400">
                {result.logs}
              </pre>
            )}
          </>
        )}
      </div>
    </div>
  );
}