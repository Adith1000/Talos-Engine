# Pipeline Builder

Visual, node-based GitHub Actions builder. Construct a CI/CD DAG on a canvas,
configure each step, set repo secrets, and the backend compiles the graph into a
real `.github/workflows/ci.yml`, encrypts + pushes any secrets, then injects and
pushes the workflow via an isolated `alpine/git` container.

```
┌─────────────────────────── frontend (React + Vite + Tailwind + React Flow) ──┐
│  NodePalette ──drag──▶ ReactFlow canvas ──select──▶ ConfigPanel              │
│                              │                         SecretsModal           │
│                    buildRunPayload()  →  POST /api/run                        │
└──────────────────────────────────────────────────────────────────────────────┘
                                   │  { nodes, edges, framework, target, secrets }
                                   ▼
┌─────────────────────────── backend (FastAPI) ────────────────────────────────┐
│  api.py            validate request, orchestrate                              │
│  payload_generator.compile_workflow()   DAG ─topo-sort─▶ YAML                 │
│  secrets_manager.set_repo_secrets()      libsodium sealed box ─▶ GitHub API   │
│  payload_generator.generate_shell_script()  + docker_runner.run_in_container  │
└──────────────────────────────────────────────────────────────────────────────┘
```

## How the graph becomes YAML

`compile_workflow(nodes, edges, ...)`:

1. **Topological sort** (`_topological_order`, Kahn's algorithm) orders steps by
   the edges the user drew. Cycles raise a 422.
2. Each node dispatches by `node.type` to a **modular generator**
   (`generate_checkout_step`, `generate_playwright_steps`, `generate_vercel_deploy`,
   …), each returning a list of step dicts.
3. A small hand-rolled **emitter** (`_emit_step`) serialises steps to YAML —
   deliberately not PyYAML, so `${{ secrets.X }}` expressions stay unquoted.
4. GitHub-Pages deploys auto-inject the required job `permissions` block.

Adding a new step type = add one generator + one catalog entry on the frontend.
Nothing else changes.

## Framework-aware test injection

`generate_shell_script` calls `test_file_for(framework)` so the container writes
the right fixture to the right path:

| framework  | file                         |
|------------|------------------------------|
| playwright | `tests/example.spec.ts`      |
| cypress    | `cypress/e2e/example.cy.js`  |
| jest       | `tests/example.test.js`      |
| vitest     | `tests/example.test.js`      |

## Secrets

Entered in the browser, held only in React state, sent once over the wire, then
encrypted **client-side on the server** with the repo's public key (libsodium
sealed box via PyNaCl) and `PUT` to the GitHub secrets API. They are never
written to disk or persisted in the browser. Set `push_secrets: false` to skip.

## Run

Backend:
```bash
cd backend
pip install -r requirements.txt
uvicorn api:app --reload --port 8000
```

Frontend:
```bash
cd frontend
npm install
npm run dev          # http://localhost:5173
# point at a non-default API with VITE_API_BASE=http://host:8000
```

## API surface

| Endpoint            | Purpose                                          |
|---------------------|--------------------------------------------------|
| `POST /api/run`     | compile → push secrets → inject + push workflow  |
| `POST /api/compile` | dry run, returns YAML only (UI "Preview YAML")   |
| `GET  /api/capabilities` | supported frameworks/targets + their secrets |
| `GET  /health`      | liveness                                         |

## Notes / next steps

- React Flow ships as `@xyflow/react` (v12) — the renamed, React-19-ready
  successor to the `reactflow` v11 package. Imports come from `@xyflow/react`.
- The token is currently sent per-request. For anything beyond local use, put it
  behind a short-lived session and serve the API over HTTPS.
- The container still runs `alpine/git`; only the script it receives changed.