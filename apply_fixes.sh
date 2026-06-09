#!/usr/bin/env bash
# apply_fixes.sh — writes the complete, consistent CI Pipeline Builder source tree.
# Run from the PROJECT ROOT (the folder that contains backend/ and frontend/).
set -euo pipefail

if [ ! -d backend ] || [ ! -d frontend ]; then
  echo "ERROR: run this from the project root (must contain backend/ and frontend/)." >&2
  exit 1
fi
echo "Writing source files..."

mkdir -p "backend"
cat > "backend/api.py" <<'__CIB_EOF_9f3a__'
"""
api.py  ←  FastAPI server

POST /api/run     compile graph → push secrets → inject + push via Docker
POST /api/compile dry run, returns YAML + the spec files it would write
GET  /api/capabilities   frameworks / assertions / action catalog for the UI
"""

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

import config
from schemas import RunRequest, RunResponse
from payload_generator import compile_workflow, generate_shell_script
from testcase_compiler import ASSERTIONS
from docker_runner import run_in_container
from secrets_manager import set_repo_secrets


app = FastAPI(
    title="CI Pipeline Builder API",
    description="Compiles a 7-node-type graph into GitHub Actions YAML + test specs.",
    version="3.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=config.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health_check():
    return {"status": "ok"}


@app.get("/api/capabilities")
def capabilities():
    return {
        "frameworks": ["playwright", "cypress", "jest", "vitest", "bash"],
        "assertions": ASSERTIONS,
        "common_actions": [
            "actions/checkout@v4",
            "actions/setup-node@v4",
            "actions/upload-artifact@v4",
            "actions/download-artifact@v4",
            "actions/cache@v4",
            "actions/upload-pages-artifact@v3",
            "actions/deploy-pages@v4",
        ],
    }


@app.post("/api/compile")
def compile_only(payload: RunRequest):
    nodes, edges = payload.graph()
    try:
        yml, specs = compile_workflow(nodes, edges)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {"compiled_yaml": yml, "spec_files": [{"path": p, "content": c} for p, c in specs]}


@app.post("/api/run", response_model=RunResponse)
def run_workflow(payload: RunRequest):
    nodes, edges = payload.graph()

    # 1. compile
    try:
        ci_yml, spec_files = compile_workflow(nodes, edges)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    # 2. push secrets
    secrets_written: list[str] = []
    if payload.push_secrets and payload.secrets:
        try:
            secrets_written = set_repo_secrets(payload.repo_url, payload.access_token, payload.secrets)
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"Failed to set repo secrets: {exc}") from exc

    # 3. inject + push
    shell_script = generate_shell_script(
        repo_url=payload.repo_url,
        branch=payload.branch,
        container_clone_dir=config.CONTAINER_CLONE_DIR,
        ci_yml_content=ci_yml,
        spec_files=spec_files,
    )
    try:
        logs = run_in_container(
            shell_script=shell_script,
            access_token=payload.access_token,
            image=config.DOCKER_IMAGE,
            timeout=config.CONTAINER_TIMEOUT,
            stream_to_stdout=True,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Unexpected error: {exc}") from exc

    return RunResponse(
        success=True,
        logs=logs,
        message="Pipeline compiled, secrets set, and workflow pushed successfully.",
        compiled_yaml=ci_yml,
        spec_files=[p for p, _ in spec_files],
        secrets_written=secrets_written,
    )


if __name__ == "__main__":
    uvicorn.run("api:app", host=config.API_HOST, port=config.API_PORT, reload=False)
__CIB_EOF_9f3a__
echo "  wrote backend/api.py"

mkdir -p "backend"
cat > "backend/config.py" <<'__CIB_EOF_9f3a__'
"""
config.py

Central configuration: environment variables, defaults, and constants.
All runtime settings are loaded here once and imported by other modules.
"""

import os
from dotenv import load_dotenv

load_dotenv()


# ─── Git / Repository ────────────────────────────────────────────────────────

REPO_URL: str = os.getenv("REPO_URL", "")
GIT_TOKEN: str = os.getenv("GIT_TOKEN", "")
BRANCH: str = os.getenv("BRANCH", "main")


# ─── Docker ──────────────────────────────────────────────────────────────────

DOCKER_IMAGE: str = os.getenv("DOCKER_IMAGE", "alpine/git:latest")
CONTAINER_CLONE_DIR: str = "/repo"
CONTAINER_TIMEOUT: int = int(os.getenv("CONTAINER_TIMEOUT", "300"))


# ─── FastAPI Server ───────────────────────────────────────────────────────────

API_HOST: str = os.getenv("API_HOST", "0.0.0.0")
API_PORT: int = int(os.getenv("API_PORT", "8000"))

_raw_origins = os.getenv("CORS_ORIGINS", "http://localhost:5173,http://localhost:3000")
CORS_ORIGINS: list[str] = [o.strip() for o in _raw_origins.split(",") if o.strip()]


# ─── Pipeline capability registry ─────────────────────────────────────────────
# These are the single source of truth shared (conceptually) with the frontend.
# Keep the keys stable; the YAML compiler dispatches on them.

SUPPORTED_FRAMEWORKS: set[str] = {"playwright", "cypress", "jest", "vitest", "none"}
SUPPORTED_DEPLOY_TARGETS: set[str] = {"vercel", "github-pages", "aws-s3", "none"}

# Which secret names each deploy target expects. Used for validation + UI hints.
TARGET_SECRETS: dict[str, list[str]] = {
    "vercel": ["VERCEL_TOKEN", "VERCEL_ORG_ID", "VERCEL_PROJECT_ID"],
    "github-pages": [],  # uses the built-in GITHUB_TOKEN
    "aws-s3": ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_S3_BUCKET"],
    "none": [],
}


# ─── Validation helper ────────────────────────────────────────────────────────

def validate_required() -> None:
    """Raise SystemExit if mandatory env vars are missing (used by CLI entry-point)."""
    missing = [name for name, val in [("GIT_TOKEN", GIT_TOKEN), ("REPO_URL", REPO_URL)] if not val]
    if missing:
        raise SystemExit(f"Error: missing required environment variables: {', '.join(missing)}")
__CIB_EOF_9f3a__
echo "  wrote backend/config.py"

mkdir -p "backend"
cat > "backend/docker_runner.py" <<'__CIB_EOF_9f3a__'
"""
docker_runner.py

Handles all Docker SDK interaction:
  - Pulling / reusing the container image
  - Creating, starting, streaming, and removing the container
  - Returning the full log output or raising on non-zero exit

No bash logic lives here; the script is received as a plain string argument
from payload_generator.generate_shell_script().
"""

import time
import docker
from docker.models.containers import Container


# ─── Public API ──────────────────────────────────────────────────────────────

def run_in_container(
    shell_script: str,
    access_token: str,
    image: str = "alpine/git:latest",
    timeout: int = 300,
    stream_to_stdout: bool = True,
) -> str:
    """
    Spin up a Docker container, execute *shell_script* inside it, and return
    the combined stdout+stderr log string.

    Parameters
    ----------
    shell_script      : The complete /bin/sh script to execute (built by payload_generator)
    access_token      : GitHub PAT injected as the GIT_TOKEN env variable
    image             : Docker image to use (must have /bin/sh and git)
    timeout           : Seconds before the container is force-killed
    stream_to_stdout  : If True, prints each log chunk live as the container runs

    Returns
    -------
    Full combined log string on success.

    Raises
    ------
    RuntimeError  : Container timed out, or exited with a non-zero status code.
    docker.errors.DockerException : Docker daemon unreachable or other SDK error.
    """
    client = docker.from_env()

    if stream_to_stdout:
        print(f"[docker_runner] Pulling / reusing image: {image}")

    container: Container = client.containers.create(
        image=image,
        entrypoint=["/bin/sh", "-c"],
        command=[shell_script],
        environment={"GIT_TOKEN": access_token},
        tty=False,
        stdin_open=False,
        detach=True,
        working_dir="/",
    )

    try:
        container.start()
        logs = _stream_logs(container, timeout=timeout, stream_to_stdout=stream_to_stdout)
        _assert_exit_zero(container, logs)
        return logs

    finally:
        _safe_remove(container)


# ─── Helpers ─────────────────────────────────────────────────────────────────

def _stream_logs(container: Container, timeout: int, stream_to_stdout: bool) -> str:
    """Stream container logs until the process exits or *timeout* is reached."""
    chunks: list[str] = []
    start = time.time()

    for raw_chunk in container.logs(stream=True, stdout=True, stderr=True, follow=True):
        text = raw_chunk.decode("utf-8", errors="replace")
        chunks.append(text)

        if stream_to_stdout:
            print(text, end="", flush=True)

        if time.time() - start > timeout:
            container.kill()
            raise RuntimeError(
                f"Container exceeded the {timeout}s timeout and was forcibly killed."
            )

    return "".join(chunks)


def _assert_exit_zero(container: Container, logs: str) -> None:
    """Raise RuntimeError if the container exited with a non-zero status."""
    result = container.wait()
    code: int = result.get("StatusCode", -1)
    if code != 0:
        raise RuntimeError(
            f"Container exited with status {code}.\n\n--- Logs ---\n{logs}"
        )


def _safe_remove(container: Container) -> None:
    """Best-effort container cleanup; swallows all errors."""
    try:
        container.remove(force=True)
    except Exception:
        pass
__CIB_EOF_9f3a__
echo "  wrote backend/docker_runner.py"

mkdir -p "backend"
cat > "backend/main.py" <<'__CIB_EOF_9f3a__'
"""
main.py  ←  CLI entry point (no HTTP server)

Runs a default linear pipeline (checkout → setup → install → test → deploy)
straight from env vars, using the same compiler the API uses.

    python main.py
"""

import config
from payload_generator import compile_workflow, generate_shell_script
from docker_runner import run_in_container


def _default_graph(framework: str, target: str):
    """A simple linear DAG mirroring the original monolith's behaviour."""
    nodes = [
        {"id": "n1", "type": "checkout", "data": {}},
        {"id": "n2", "type": "setup-node", "data": {"nodeVersion": "20"}},
        {"id": "n3", "type": "install", "data": {}},
        {"id": "n4", "type": "test", "data": {"framework": framework}},
        {"id": "n5", "type": "deploy", "data": {"target": target}},
    ]
    edges = [
        {"source": "n1", "target": "n2"},
        {"source": "n2", "target": "n3"},
        {"source": "n3", "target": "n4"},
        {"source": "n4", "target": "n5"},
    ]
    return nodes, edges


def main() -> None:
    config.validate_required()

    framework, target = "playwright", "vercel"
    nodes, edges = _default_graph(framework, target)

    print(f"[main] Repo  : {config.REPO_URL}")
    print(f"[main] Branch: {config.BRANCH}")
    print(f"[main] Image : {config.DOCKER_IMAGE}\n")

    ci_yml = compile_workflow(
        nodes, edges,
        testing_framework=framework,
        deployment_target=target,
    )

    shell_script = generate_shell_script(
        repo_url=config.REPO_URL,
        branch=config.BRANCH,
        container_clone_dir=config.CONTAINER_CLONE_DIR,
        ci_yml_content=ci_yml,
        testing_framework=framework,
    )

    logs = run_in_container(
        shell_script=shell_script,
        access_token=config.GIT_TOKEN,
        image=config.DOCKER_IMAGE,
        timeout=config.CONTAINER_TIMEOUT,
        stream_to_stdout=True,
    )

    print("\n=== CONTAINER LOGS ===")
    print(logs)
    print("[main] Done.")


if __name__ == "__main__":
    main()
__CIB_EOF_9f3a__
echo "  wrote backend/main.py"

mkdir -p "backend"
cat > "backend/payload_generator.py" <<'__CIB_EOF_9f3a__'
"""
payload_generator.py

Compiles the visual node graph into a GitHub Actions workflow + the test spec
files it references, then builds the /bin/sh script the container runs.

Node model (7 core types + testsuite) maps onto the Actions object model:

    workflow   → top-level   name:
    event      → top-level   on:
    job        → jobs.<id>:  (runs-on / needs / timeout-minutes / env)
    runner     → sets a job's runs-on (hosted image, or self-hosted labels)
    step       → a run:/uses: step inside its owning job
    action     → a uses: step (with: args) inside its owning job
    secrets    → injects secrets/vars into its owning job's env
    testsuite  → emits test steps + writes generated spec files

Ownership: a non-job node belongs to the nearest job reachable by an undirected
edge walk. Steps inside a job are ordered by the directed edges among them.

Public API
----------
compile_workflow(nodes, edges) -> (yaml_str, spec_files)
generate_shell_script(repo_url, branch, clone_dir, ci_yml, spec_files) -> str
"""

from __future__ import annotations

import textwrap
from collections import defaultdict, deque

from testcase_compiler import compile_test_files, test_run_steps


# ══════════════════════════════════════════════════════════════════════════════
#  Tiny YAML emitter
#  Hand-rolled because (a) PyYAML reorders/quotes keys, and (b) the key `on`
#  parses as the boolean True in YAML 1.1 — both fatal for Actions files.
#  Multi-line strings become block scalars (|). Lists/dicts nest recursively.
# ══════════════════════════════════════════════════════════════════════════════

_YAML_BOOLS = {"true", "false", "yes", "no", "on", "off", "null", "~"}


def _scalar(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    s = str(v)
    needs_quote = (
        s == ""
        or s != s.strip()
        or s.lower() in _YAML_BOOLS
        or ": " in s
        or " #" in s
        or s[0] in "!&*?|>%@`\"'#,{}[]-"
    )
    if needs_quote:
        return "'" + s.replace("'", "''") + "'"
    return s


def _dump(obj, indent: int = 0) -> str:
    pad = "  " * indent
    out: list[str] = []

    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, dict) and v:
                out.append(f"{pad}{k}:")
                out.append(_dump(v, indent + 1))
            elif isinstance(v, list) and v:
                out.append(f"{pad}{k}:")
                out.append(_dump(v, indent + 1))
            elif isinstance(v, str) and "\n" in v:
                out.append(f"{pad}{k}: |")
                bpad = "  " * (indent + 1)
                for ln in v.rstrip("\n").split("\n"):
                    out.append(f"{bpad}{ln}" if ln else "")
            elif v is None or v == {} or v == []:
                out.append(f"{pad}{k}:")
            else:
                out.append(f"{pad}{k}: {_scalar(v)}")

    elif isinstance(obj, list):
        for item in obj:
            if isinstance(item, dict) and item:
                inner = _dump(item, indent + 1).split("\n")
                first = inner[0][len("  " * (indent + 1)):]
                out.append(f"{pad}- {first}")
                out.extend(inner[1:])
            elif isinstance(item, str) and "\n" in item:
                out.append(f"{pad}- |")
                bpad = "  " * (indent + 1)
                for ln in item.rstrip("\n").split("\n"):
                    out.append(f"{bpad}{ln}" if ln else "")
            else:
                out.append(f"{pad}- {_scalar(item)}")

    return "\n".join(out)


# ══════════════════════════════════════════════════════════════════════════════
#  Graph helpers
# ══════════════════════════════════════════════════════════════════════════════

def _undirected_adj(nodes, edges):
    adj = defaultdict(set)
    ids = {n["id"] for n in nodes}
    for e in edges:
        s, t = e.get("source"), e.get("target")
        if s in ids and t in ids:
            adj[s].add(t)
            adj[t].add(s)
    return adj


def _nearest_job(start, by_id, adj, order_index):
    """BFS undirected from `start`; return the id of the closest 'job' node."""
    seen = {start}
    q = deque([start])
    while q:
        cur = q.popleft()
        for nxt in sorted(adj[cur], key=lambda x: order_index.get(x, 0)):
            if nxt in seen:
                continue
            if by_id[nxt]["type"] == "job":
                return nxt
            seen.add(nxt)
            q.append(nxt)
    return None


def _order_within(member_ids, edges, order_index):
    """Topologically order a job's step/action/testsuite members by the directed
    edges among *them*; ties and disconnected nodes fall back to node order."""
    member = set(member_ids)
    indeg = {m: 0 for m in member}
    adj = defaultdict(list)
    for e in edges:
        s, t = e.get("source"), e.get("target")
        if s in member and t in member:
            adj[s].append(t)
            indeg[t] += 1
    ready = deque(sorted((m for m in member if indeg[m] == 0),
                         key=lambda x: order_index[x]))
    ordered = []
    while ready:
        m = ready.popleft()
        ordered.append(m)
        for nxt in sorted(adj[m], key=lambda x: order_index[x]):
            indeg[nxt] -= 1
            if indeg[nxt] == 0:
                ready.append(nxt)
    for m in sorted(member, key=lambda x: order_index[x]):
        if m not in ordered:
            ordered.append(m)
    return ordered


# ══════════════════════════════════════════════════════════════════════════════
#  Per-node step builders (return list of step dicts)
# ══════════════════════════════════════════════════════════════════════════════

def _step_from_step_node(data: dict) -> list[dict]:
    step = {"name": data.get("name") or "Step"}
    if data.get("mode") == "uses" and data.get("uses"):
        step["uses"] = data["uses"]
    else:
        step["run"] = data.get("run") or "echo 'no command'"
    if data.get("env"):
        step["env"] = dict(data["env"])
    return [step]


def _step_from_action_node(data: dict) -> list[dict]:
    step = {"name": data.get("name") or data.get("action") or "Action",
            "uses": data.get("action") or "actions/checkout@v4"}
    with_args = {k: v for k, v in (data.get("withArgs") or {}).items() if v not in ("", None)}
    if with_args:
        step["with"] = with_args
    return [step]


def _steps_from_testsuite_node(data: dict) -> list[dict]:
    return test_run_steps(data.get("framework") or "playwright")


_PAGES_ACTIONS = {"actions/deploy-pages@v4", "actions/upload-pages-artifact@v3"}


# ══════════════════════════════════════════════════════════════════════════════
#  Compiler
# ══════════════════════════════════════════════════════════════════════════════

def compile_workflow(nodes: list[dict], edges: list[dict]) -> tuple[str, list[tuple[str, str]]]:
    by_id = {n["id"]: n for n in nodes}
    order_index = {n["id"]: i for i, n in enumerate(nodes)}
    adj = _undirected_adj(nodes, edges)

    workflow_nodes = [n for n in nodes if n["type"] == "workflow"]
    event_nodes = [n for n in nodes if n["type"] == "event"]
    job_nodes = [n for n in nodes if n["type"] == "job"]
    runner_nodes = [n for n in nodes if n["type"] == "runner"]
    secrets_nodes = [n for n in nodes if n["type"] == "secrets"]
    exec_types = {"step", "action", "testsuite"}
    exec_nodes = [n for n in nodes if n["type"] in exec_types]

    # ── name ──────────────────────────────────────────────────────────────
    wf_name = (workflow_nodes[0]["data"].get("name") if workflow_nodes else None) or "CI Pipeline"

    # ── on: ───────────────────────────────────────────────────────────────
    on_block: dict = {}
    push_branches, pr_branches, crons = [], [], []
    have_push = have_pr = have_dispatch = False
    for n in event_nodes:
        d = n["data"]
        trg = d.get("triggers", [])
        if "push" in trg:
            have_push = True
            push_branches += d.get("push_branches", [])
        if "pull_request" in trg:
            have_pr = True
            pr_branches += d.get("pull_request_branches", [])
        if "workflow_dispatch" in trg:
            have_dispatch = True
        if "schedule" in trg and d.get("cron"):
            crons.append(d["cron"])

    if not event_nodes:
        have_push, push_branches, have_dispatch = True, ["main"], True

    if have_push:
        on_block["push"] = {"branches": sorted(set(push_branches))} if push_branches else None
    if have_pr:
        on_block["pull_request"] = {"branches": sorted(set(pr_branches))} if pr_branches else None
    if have_dispatch:
        on_block["workflow_dispatch"] = None
    if crons:
        on_block["schedule"] = [{"cron": c} for c in crons]

    # ── assign every non-job node to a job ──────────────────────────────────
    if not job_nodes:
        synth = {"id": "__job__", "type": "job",
                 "data": {"jobId": "build", "runsOn": "ubuntu-latest"}}
        by_id[synth["id"]] = synth
        order_index[synth["id"]] = -1
        job_nodes = [synth]
        owner_of = {n["id"]: "__job__" for n in exec_nodes + runner_nodes + secrets_nodes}
    else:
        owner_of = {}
        default_job = min(job_nodes, key=lambda j: order_index[j["id"]])["id"]
        for n in exec_nodes + runner_nodes + secrets_nodes:
            owner_of[n["id"]] = _nearest_job(n["id"], by_id, adj, order_index) or default_job

    job_ids = {j["data"].get("jobId") or j["id"]: j["id"] for j in job_nodes}
    valid_job_keys = set(job_ids.keys())

    # ── build each job ──────────────────────────────────────────────────────
    spec_files: list[tuple[str, str]] = []
    needs_pages = False
    jobs_block: dict = {}

    for j in sorted(job_nodes, key=lambda x: order_index[x["id"]]):
        jd = j["data"]
        job_key = jd.get("jobId") or j["id"]
        my_nodes = [nid for nid, owner in owner_of.items() if owner == j["id"]]

        runs_on = jd.get("runsOn") or "ubuntu-latest"
        for nid in my_nodes:
            node = by_id[nid]
            if node["type"] == "runner":
                rd = node["data"]
                if rd.get("hosted", True):
                    runs_on = rd.get("image") or "ubuntu-latest"
                else:
                    runs_on = ["self-hosted", *rd.get("labels", [])]

        job_env: dict = {}
        for nid in my_nodes:
            node = by_id[nid]
            if node["type"] == "secrets":
                sd = node["data"]
                for name in sd.get("secrets", []):
                    job_env[name] = f"${{{{ secrets.{name} }}}}"
                for k, v in (sd.get("vars") or {}).items():
                    job_env[k] = v

        exec_ids = [nid for nid in my_nodes if by_id[nid]["type"] in exec_types]
        steps: list[dict] = []
        for nid in _order_within(exec_ids, edges, order_index):
            node = by_id[nid]
            t, d = node["type"], node["data"]
            if t == "step":
                steps += _step_from_step_node(d)
            elif t == "action":
                steps += _step_from_action_node(d)
                if d.get("action") in _PAGES_ACTIONS:
                    needs_pages = True
            elif t == "testsuite":
                spec_files += compile_test_files(d.get("framework"), d.get("testcases"))
                steps += _steps_from_testsuite_node(d)

        if not steps:
            steps = [{"name": "Noop", "run": "echo 'job has no steps'"}]

        job_obj: dict = {"runs-on": runs_on}
        needs = [n for n in jd.get("needs", []) if n in valid_job_keys and n != job_key]
        if needs:
            job_obj["needs"] = needs
        if jd.get("timeoutMinutes"):
            job_obj["timeout-minutes"] = int(jd["timeoutMinutes"])
        if job_env:
            job_obj["env"] = job_env
        job_obj["steps"] = steps

        jobs_block[job_key] = job_obj

    # ── assemble ──────────────────────────────────────────────────────────
    workflow: dict = {"name": wf_name, "on": on_block or {"workflow_dispatch": None}}
    if needs_pages:
        workflow["permissions"] = {"contents": "read", "pages": "write", "id-token": "write"}
    workflow["jobs"] = jobs_block

    return _dump(workflow) + "\n", spec_files


# ══════════════════════════════════════════════════════════════════════════════
#  Shell-script builder (runs inside the Alpine container)
# ══════════════════════════════════════════════════════════════════════════════

def _heredoc(path: str, content: str) -> str:
    body = content.rstrip("\n")
    folder = path.rsplit("/", 1)[0] if "/" in path else "."
    return (
        f'mkdir -p "{folder}"\n'
        f"cat > {path} <<'__EOF__'\n"
        f"{body}\n"
        "__EOF__\n"
    )


def generate_shell_script(
    repo_url: str,
    branch: str,
    container_clone_dir: str,
    ci_yml_content: str,
    spec_files: list[tuple[str, str]] | None = None,
) -> str:
    spec_files = spec_files or []
    safe_ci = ci_yml_content.rstrip()

    file_writes = _heredoc(".github/workflows/ci.yml", safe_ci)
    for path, content in spec_files:
        file_writes += _heredoc(path, content)

    add_paths = " ".join([".github/workflows/ci.yml", *[p for p, _ in spec_files]])

    # IMPORTANT: dedent the STATIC template first (all lines share the same
    # indent, so dedent works), THEN substitute the multi-line `file_writes`.
    # Interpolating multi-line content *before* dedent defeats dedent (its lines
    # sit at column 0, so no common indent is found) and leaves the whole script
    # indented — which breaks heredoc delimiters. Placeholders avoid that.
    template = textwrap.dedent("""\
        set -euo pipefail
        export GIT_TERMINAL_PROMPT=0

        REPO_URL="@@REPO_URL@@"
        CLONE_DIR="@@CLONE_DIR@@"
        BRANCH="@@BRANCH@@"

        repo_path="${REPO_URL#https://github.com/}"
        if [ -z "$repo_path" ]; then echo "Invalid REPO_URL: $REPO_URL" >&2; exit 2; fi
        case "$repo_path" in
          *.git) auth_path="$repo_path" ;;
          *) auth_path="${repo_path}.git" ;;
        esac

        AUTH_URL="https://x-access-token:$GIT_TOKEN@github.com/$auth_path"

        echo ">>> cloning $REPO_URL"
        git clone "$AUTH_URL" "$CLONE_DIR" || { echo "clone failed"; exit 3; }
        cd "$CLONE_DIR"

        if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
          git checkout "$BRANCH"
        else
          git checkout -b "$BRANCH"
        fi
        git remote set-url origin "https://github.com/$auth_path"

        echo ">>> writing generated files"
        @@FILE_WRITES@@
        echo ">>> staging:"
        git add @@ADD_PATHS@@
        git status --short

        if git diff --cached --quiet; then
          echo ">>> No changes to commit (files already up to date)."
        else
          echo ">>> committing..."
          git -c user.name="CI Bot (container)" -c user.email="ci-bot@example.com" \\
              commit -m "Add generated CI workflow + tests" || { echo "commit failed"; exit 4; }
          echo ">>> pushing to $BRANCH..."
          if ! git push "https://x-access-token:$GIT_TOKEN@github.com/$auth_path" "HEAD:$BRANCH" 2>&1; then
            echo "push failed — if the error mentions the 'workflow' scope, your token"
            echo "lacks permission to write .github/workflows/. Regenerate the PAT with"
            echo "the 'workflow' scope (classic) or Workflows: read/write (fine-grained)."
            exit 5
          fi
          echo ">>> push succeeded"
        fi

        echo "Container job complete."
    """)

    return (
        template
        .replace("@@FILE_WRITES@@", file_writes.rstrip("\n"))
        .replace("@@REPO_URL@@", repo_url)
        .replace("@@CLONE_DIR@@", container_clone_dir)
        .replace("@@BRANCH@@", branch)
        .replace("@@ADD_PATHS@@", add_paths)
    )
__CIB_EOF_9f3a__
echo "  wrote backend/payload_generator.py"

mkdir -p "backend"
cat > "backend/requirements.txt" <<'__CIB_EOF_9f3a__'
docker>=7.0.0
fastapi>=0.111.0
uvicorn[standard]>=0.30.0
pydantic>=2.7.0
python-dotenv>=1.0.0
python-multipart>=0.0.9   # required by FastAPI for form/file uploads
requests>=2.31.0          # GitHub REST API calls (secrets)
pynacl>=1.5.0             # libsodium sealed-box encryption for repo secrets
__CIB_EOF_9f3a__
echo "  wrote backend/requirements.txt"

mkdir -p "backend"
cat > "backend/schemas.py" <<'__CIB_EOF_9f3a__'
"""
schemas.py

Rich request schemas. Each node type carries a typed `data` model, combined
into a discriminated union on `type`, so the API validates (and documents) the
full configuration surface of every node.

These models mirror the frontend node catalog. The compiler in
payload_generator.py consumes plain dicts (model_dump), so the schemas are the
validation + OpenAPI layer; the compiler stays decoupled and unit-testable.
"""

from __future__ import annotations

from typing import Annotated, Literal, Union

from pydantic import BaseModel, Field, field_validator


# ─── Testcase ─────────────────────────────────────────────────────────────────

AssertionType = Literal["contains_text", "element_visible", "status_code", "url_contains"]


class TestCase(BaseModel):
    title: str = "Untitled test"
    route: str = "/"
    assertion: AssertionType = "contains_text"
    expected: str = ""


# ─── Per-node data models ─────────────────────────────────────────────────────

class WorkflowData(BaseModel):
    name: str = "CI Pipeline"


class EventData(BaseModel):
    triggers: list[Literal["push", "pull_request", "workflow_dispatch", "schedule"]] = ["push"]
    push_branches: list[str] = Field(default_factory=lambda: ["main"])
    pull_request_branches: list[str] = Field(default_factory=list)
    cron: str = ""


class JobData(BaseModel):
    jobId: str = "build"
    runsOn: str = "ubuntu-latest"
    timeoutMinutes: int | None = None
    needs: list[str] = Field(default_factory=list)


class RunnerData(BaseModel):
    hosted: bool = True
    image: str = "ubuntu-latest"
    labels: list[str] = Field(default_factory=list)


class StepData(BaseModel):
    name: str = "Step"
    mode: Literal["run", "uses"] = "run"
    run: str = ""
    uses: str = ""
    env: dict[str, str] = Field(default_factory=dict)


class ActionData(BaseModel):
    name: str = ""
    action: str = "actions/checkout@v4"
    withArgs: dict[str, str] = Field(default_factory=dict)


class SecretsData(BaseModel):
    secrets: list[str] = Field(default_factory=list)
    vars: dict[str, str] = Field(default_factory=dict)


class TestSuiteData(BaseModel):
    framework: Literal["playwright", "cypress", "jest", "vitest", "bash"] = "playwright"
    testcases: list[TestCase] = Field(default_factory=list)


# ─── Node union ───────────────────────────────────────────────────────────────
# Each variant pins `type` to a literal; Pydantic uses it as the discriminator.

class _BaseNode(BaseModel):
    id: str


class WorkflowNode(_BaseNode):
    type: Literal["workflow"]
    data: WorkflowData = WorkflowData()


class EventNode(_BaseNode):
    type: Literal["event"]
    data: EventData = EventData()


class JobNode(_BaseNode):
    type: Literal["job"]
    data: JobData = JobData()


class RunnerNode(_BaseNode):
    type: Literal["runner"]
    data: RunnerData = RunnerData()


class StepNode(_BaseNode):
    type: Literal["step"]
    data: StepData = StepData()


class ActionNode(_BaseNode):
    type: Literal["action"]
    data: ActionData = ActionData()


class SecretsNode(_BaseNode):
    type: Literal["secrets"]
    data: SecretsData = SecretsData()


class TestSuiteNode(_BaseNode):
    type: Literal["testsuite"]
    data: TestSuiteData = TestSuiteData()


PipelineNode = Annotated[
    Union[
        WorkflowNode, EventNode, JobNode, RunnerNode,
        StepNode, ActionNode, SecretsNode, TestSuiteNode,
    ],
    Field(discriminator="type"),
]


class FlowEdge(BaseModel):
    id: str | None = None
    source: str
    target: str


# ─── Top-level request ────────────────────────────────────────────────────────

class RunRequest(BaseModel):
    repo_url: str
    access_token: str
    branch: str = "main"

    nodes: list[PipelineNode]
    edges: list[FlowEdge] = Field(default_factory=list)

    # name -> value; pushed to GitHub as encrypted repo secrets
    secrets: dict[str, str] = Field(default_factory=dict)
    push_secrets: bool = True

    @field_validator("repo_url")
    @classmethod
    def must_be_github(cls, v: str) -> str:
        if not v.startswith("https://github.com/"):
            raise ValueError("repo_url must start with https://github.com/")
        return v.strip()

    @field_validator("access_token")
    @classmethod
    def token_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("access_token must not be empty")
        return v.strip()

    @field_validator("nodes")
    @classmethod
    def non_empty(cls, v: list) -> list:
        if not v:
            raise ValueError("Pipeline must contain at least one node")
        return v

    def graph(self) -> tuple[list[dict], list[dict]]:
        """Plain-dict form for the compiler."""
        return (
            [n.model_dump() for n in self.nodes],
            [e.model_dump() for e in self.edges],
        )


class RunResponse(BaseModel):
    success: bool
    logs: str
    message: str
    compiled_yaml: str
    spec_files: list[str]
    secrets_written: list[str]
__CIB_EOF_9f3a__
echo "  wrote backend/schemas.py"

mkdir -p "backend"
cat > "backend/secrets_manager.py" <<'__CIB_EOF_9f3a__'
"""
secrets_manager.py

Sets repository secrets on GitHub via the REST API so the generated workflow's
"${{ secrets.X }}" references actually resolve.

GitHub requires each secret value to be encrypted client-side with the repo's
public key using a libsodium *sealed box* before upload. We use PyNaCl for that.

Docs: https://docs.github.com/en/rest/actions/secrets
"""

from __future__ import annotations

import base64
from urllib.parse import urlparse

import requests
from nacl import encoding, public

_API = "https://api.github.com"


def _owner_repo(repo_url: str) -> tuple[str, str]:
    path = urlparse(repo_url).path.strip("/")
    if path.endswith(".git"):
        path = path[:-4]
    parts = path.split("/")
    if len(parts) < 2:
        raise ValueError(f"Cannot parse owner/repo from {repo_url!r}")
    return parts[0], parts[1]


def _headers(token: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }


def _encrypt(public_key_b64: str, secret_value: str) -> str:
    """Seal `secret_value` against the repo's base64 public key."""
    pk = public.PublicKey(public_key_b64.encode("utf-8"), encoding.Base64Encoder())
    sealed = public.SealedBox(pk).encrypt(secret_value.encode("utf-8"))
    return base64.b64encode(sealed).decode("utf-8")


def set_repo_secrets(repo_url: str, token: str, secrets: dict[str, str]) -> list[str]:
    """
    Upload each name->value pair as an Actions repository secret.
    Returns the list of secret names that were written.
    Raises requests.HTTPError on API failure.
    """
    if not secrets:
        return []

    owner, repo = _owner_repo(repo_url)
    h = _headers(token)

    key_resp = requests.get(
        f"{_API}/repos/{owner}/{repo}/actions/secrets/public-key", headers=h, timeout=30
    )
    key_resp.raise_for_status()
    key_data = key_resp.json()
    public_key, key_id = key_data["key"], key_data["key_id"]

    written: list[str] = []
    for name, value in secrets.items():
        if value is None or value == "":
            continue
        payload = {"encrypted_value": _encrypt(public_key, value), "key_id": key_id}
        put = requests.put(
            f"{_API}/repos/{owner}/{repo}/actions/secrets/{name}",
            headers=h, json=payload, timeout=30,
        )
        put.raise_for_status()
        written.append(name)

    return written
__CIB_EOF_9f3a__
echo "  wrote backend/secrets_manager.py"

mkdir -p "backend"
cat > "backend/testcase_compiler.py" <<'__CIB_EOF_9f3a__'
"""
testcase_compiler.py

Turns the UI-authored testcase list into real, runnable test files and the CI
steps that execute them.

A testcase is a dict:
    {
      "title":     "Login page loads",
      "route":     "/login",
      "assertion": "contains_text" | "element_visible" | "status_code" | "url_contains",
      "expected":  "Sign in"        # text, selector, status code, or url fragment
    }

Public API
----------
compile_test_files(framework, testcases) -> list[(path, content)]
    The spec file(s) + framework config to write into the repo.

test_run_steps(framework) -> list[step-dict]
    The CI steps that install + run that framework.

ASSERTIONS                  -> the assertion catalog (shared shape with the UI).
"""

from __future__ import annotations

import textwrap

# Assertion catalog — kept in sync with the frontend dropdown.
ASSERTIONS = [
    {"value": "contains_text", "label": "Page contains text"},
    {"value": "element_visible", "label": "Element is visible (selector)"},
    {"value": "status_code", "label": "Status code is"},
    {"value": "url_contains", "label": "URL contains"},
]


# ─── escaping helpers ─────────────────────────────────────────────────────────

def _js(s: str) -> str:
    """Escape a value for embedding inside a single-quoted JS/TS string."""
    return (str(s) or "").replace("\\", "\\\\").replace("'", "\\'").replace("\n", " ")


def _sh(s: str) -> str:
    """Escape for a double-quoted shell string."""
    return (str(s) or "").replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")


# ══════════════════════════════════════════════════════════════════════════════
#  Playwright  →  tests/generated.spec.ts  (+ playwright.config.ts)
# ══════════════════════════════════════════════════════════════════════════════

def _playwright_assertion(tc: dict) -> str:
    a, exp = tc.get("assertion"), _js(tc.get("expected", ""))
    if a == "contains_text":
        return f"await expect(page.getByText('{exp}', {{ exact: false }})).toBeVisible();"
    if a == "element_visible":
        return f"await expect(page.locator('{exp}')).toBeVisible();"
    if a == "status_code":
        return f"expect(response?.status()).toBe(Number('{exp}'));"
    if a == "url_contains":
        return f"await expect(page).toHaveURL(new RegExp('{exp}'));"
    return "expect(true).toBeTruthy();"


def _playwright_files(testcases: list[dict]) -> list[tuple[str, str]]:
    blocks = []
    for tc in testcases:
        route = _js(tc.get("route", "/"))
        blocks.append(textwrap.dedent(f"""\
            test('{_js(tc.get("title", "test"))}', async ({{ page }}) => {{
              const response = await page.goto('{route}');
              {_playwright_assertion(tc)}
            }});
        """))
    spec = (
        "import { test, expect } from '@playwright/test';\n\n"
        + "\n".join(blocks)
    )
    config = textwrap.dedent("""\
        import { defineConfig, devices } from '@playwright/test';
        export default defineConfig({
          testDir: './tests',
          reporter: 'html',
          use: { baseURL: 'http://localhost:5173', trace: 'on-first-retry' },
          projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
          webServer: {
            command: 'npx vite --port 5173',
            url: 'http://localhost:5173',
            reuseExistingServer: !process.env.CI,
            timeout: 120 * 1000,
          },
        });
    """)
    return [("playwright.config.ts", config), ("tests/generated.spec.ts", spec)]


def _playwright_steps() -> list[dict]:
    return [
        {"name": "Install Playwright",
         "run": "npm install --no-save @playwright/test\nnpx playwright install --with-deps"},
        {"name": "Run Playwright tests", "run": "npx playwright test"},
        {"name": "Upload Playwright report", "if": "${{ always() }}",
         "uses": "actions/upload-artifact@v4",
         "with": {"name": "playwright-report", "path": "playwright-report/", "retention-days": 30}},
    ]


# ══════════════════════════════════════════════════════════════════════════════
#  Cypress  →  cypress/e2e/generated.cy.js  (+ cypress.config.js)
# ══════════════════════════════════════════════════════════════════════════════

def _cypress_assertion(tc: dict) -> str:
    a, exp, route = tc.get("assertion"), _js(tc.get("expected", "")), _js(tc.get("route", "/"))
    if a == "contains_text":
        return f"cy.contains('{exp}').should('be.visible');"
    if a == "element_visible":
        return f"cy.get('{exp}').should('be.visible');"
    if a == "status_code":
        return f"cy.request('{route}').its('status').should('eq', Number('{exp}'));"
    if a == "url_contains":
        return f"cy.url().should('include', '{exp}');"
    return "expect(true).to.be.true;"


def _cypress_files(testcases: list[dict]) -> list[tuple[str, str]]:
    blocks = []
    for tc in testcases:
        route = _js(tc.get("route", "/"))
        blocks.append(textwrap.dedent(f"""\
            it('{_js(tc.get("title", "test"))}', () => {{
              cy.visit('{route}');
              {_cypress_assertion(tc)}
            }});
        """))
    spec = "describe('Generated suite', () => {\n" + "\n".join(blocks) + "});\n"
    config = textwrap.dedent("""\
        const { defineConfig } = require('cypress');
        module.exports = defineConfig({
          e2e: { baseUrl: 'http://localhost:5173', supportFile: false },
        });
    """)
    return [("cypress.config.js", config), ("cypress/e2e/generated.cy.js", spec)]


def _cypress_steps() -> list[dict]:
    return [
        {"name": "Run Cypress tests", "uses": "cypress-io/github-action@v6",
         "with": {"start": "npx vite --port 5173", "wait-on": "http://localhost:5173"}},
    ]


# ══════════════════════════════════════════════════════════════════════════════
#  Jest / Vitest  →  tests/generated.test.js
# ══════════════════════════════════════════════════════════════════════════════

def _unit_files(testcases: list[dict], runner: str) -> list[tuple[str, str]]:
    header = (
        "import { test, expect } from 'vitest';\n\n"
        if runner == "vitest"
        else "/* jest */\n\n"
    )
    blocks = []
    for tc in testcases:
        title = _js(tc.get("title", "test"))
        if tc.get("assertion") == "status_code":
            route = _js(tc.get("route", "/"))
            exp = _js(tc.get("expected", "200"))
            blocks.append(textwrap.dedent(f"""\
                test('{title}', async () => {{
                  const res = await fetch('http://localhost:5173{route}');
                  expect(res.status).toBe(Number('{exp}'));
                }});
            """))
        else:
            # Unit runners can't drive a browser; emit a documented placeholder.
            blocks.append(textwrap.dedent(f"""\
                test('{title}', () => {{
                  // route={_js(tc.get("route", ""))} assertion={_js(tc.get("assertion", ""))} expected={_js(tc.get("expected", ""))}
                  expect(true).toBe(true);
                }});
            """))
    return [("tests/generated.test.js", header + "\n".join(blocks))]


def _jest_steps() -> list[dict]:
    return [
        {"name": "Install Jest", "run": "npm install --no-save jest"},
        {"name": "Run Jest", "run": "npx jest --ci"},
    ]


def _vitest_steps() -> list[dict]:
    return [
        {"name": "Install Vitest", "run": "npm install --no-save vitest"},
        {"name": "Run Vitest", "run": "npx vitest run"},
    ]


# ══════════════════════════════════════════════════════════════════════════════
#  Bash  →  tests/run_tests.sh
# ══════════════════════════════════════════════════════════════════════════════

def _bash_files(testcases: list[dict]) -> list[tuple[str, str]]:
    lines = ["#!/bin/sh", "set -e", 'BASE="${BASE_URL:-http://localhost:5173}"', ""]
    for tc in testcases:
        title = _sh(tc.get("title", "test"))
        route = _sh(tc.get("route", "/"))
        exp = _sh(tc.get("expected", ""))
        lines.append(f'echo ">>> {title}"')
        if tc.get("assertion") == "status_code":
            lines.append(f'code=$(curl -s -o /dev/null -w "%{{http_code}}" "$BASE{route}")')
            lines.append(f'[ "$code" = "{exp}" ] || {{ echo "FAIL ({title}): got $code"; exit 1; }}')
        else:  # contains_text / fallback
            lines.append(f'curl -s "$BASE{route}" | grep -q "{exp}" || {{ echo "FAIL ({title})"; exit 1; }}')
        lines.append("")
    lines.append('echo "All bash testcases passed."')
    return [("tests/run_tests.sh", "\n".join(lines) + "\n")]


def _bash_steps() -> list[dict]:
    return [
        {"name": "Run bash tests",
         "run": "chmod +x tests/run_tests.sh\nnpx vite --port 5173 &\nsleep 5\n./tests/run_tests.sh"},
    ]


# ══════════════════════════════════════════════════════════════════════════════
#  Dispatch
# ══════════════════════════════════════════════════════════════════════════════

_FILE_COMPILERS = {
    "playwright": _playwright_files,
    "cypress": _cypress_files,
    "jest": lambda tcs: _unit_files(tcs, "jest"),
    "vitest": lambda tcs: _unit_files(tcs, "vitest"),
    "bash": _bash_files,
}

_STEP_COMPILERS = {
    "playwright": _playwright_steps,
    "cypress": _cypress_steps,
    "jest": _jest_steps,
    "vitest": _vitest_steps,
    "bash": _bash_steps,
}


def compile_test_files(framework: str, testcases: list[dict]) -> list[tuple[str, str]]:
    fw = (framework or "playwright").lower()
    fn = _FILE_COMPILERS.get(fw, _playwright_files)
    return fn(testcases or [])


def test_run_steps(framework: str) -> list[dict]:
    fw = (framework or "playwright").lower()
    fn = _STEP_COMPILERS.get(fw, _playwright_steps)
    return fn()
__CIB_EOF_9f3a__
echo "  wrote backend/testcase_compiler.py"

mkdir -p "frontend"
cat > "frontend/index.html" <<'__CIB_EOF_9f3a__'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link
      href="https://fonts.googleapis.com/css2?family=Archivo:wght@500;600;700;800&family=JetBrains+Mono:wght@400;500;600;700&display=swap"
      rel="stylesheet"
    />
    <title>Pipeline Builder</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
__CIB_EOF_9f3a__
echo "  wrote frontend/index.html"

mkdir -p "frontend"
cat > "frontend/package.json" <<'__CIB_EOF_9f3a__'
{
  "name": "frontend",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "lint": "eslint .",
    "preview": "vite preview"
  },
  "dependencies": {
    "@xyflow/react": "^12.3.5",
    "react": "^19.2.6",
    "react-dom": "^19.2.6"
  },
  "devDependencies": {
    "@eslint/js": "^10.0.1",
    "@types/react": "^19.2.14",
    "@types/react-dom": "^19.2.3",
    "@vitejs/plugin-react": "^6.0.1",
    "autoprefixer": "^10.5.0",
    "eslint": "^10.3.0",
    "eslint-plugin-react-hooks": "^7.1.1",
    "eslint-plugin-react-refresh": "^0.5.2",
    "globals": "^17.6.0",
    "postcss": "^8.5.15",
    "tailwindcss": "^3.4.19",
    "vite": "^8.0.12"
  }
}
__CIB_EOF_9f3a__
echo "  wrote frontend/package.json"

mkdir -p "frontend"
cat > "frontend/tailwind.config.js" <<'__CIB_EOF_9f3a__'
/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  theme: {
    extend: {
      fontFamily: {
        mono: ['"JetBrains Mono"', "ui-monospace", "monospace"],
        display: ['"Archivo"', "system-ui", "sans-serif"],
      },
      colors: {
        ink: {
          900: "#0a0c10", // app background
          800: "#0f1217", // panels
          700: "#161a21", // cards
          600: "#1d222b", // raised
          500: "#272d39", // borders
        },
        signal: {
          DEFAULT: "#ff7a18", // primary accent (wiring orange)
          soft: "#ffb070",
        },
        // category accents
        cat: {
          checkout: "#38bdf8",
          setup: "#a78bfa",
          install: "#2dd4bf",
          test: "#f5a524",
          build: "#94a3b8",
          deploy: "#34d399",
        },
      },
      boxShadow: {
        node: "0 1px 0 rgba(255,255,255,0.03) inset, 0 8px 24px -12px rgba(0,0,0,0.8)",
      },
    },
  },
  plugins: [],
};
__CIB_EOF_9f3a__
echo "  wrote frontend/tailwind.config.js"

mkdir -p "frontend"
cat > "frontend/postcss.config.js" <<'__CIB_EOF_9f3a__'
export default {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
}
__CIB_EOF_9f3a__
echo "  wrote frontend/postcss.config.js"

mkdir -p "frontend"
cat > "frontend/vite.config.js" <<'__CIB_EOF_9f3a__'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
})
__CIB_EOF_9f3a__
echo "  wrote frontend/vite.config.js"

mkdir -p "frontend"
cat > "frontend/eslint.config.js" <<'__CIB_EOF_9f3a__'
import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import { defineConfig, globalIgnores } from 'eslint/config'

export default defineConfig([
  globalIgnores(['dist']),
  {
    files: ['**/*.{js,jsx}'],
    extends: [
      js.configs.recommended,
      reactHooks.configs.flat.recommended,
      reactRefresh.configs.vite,
    ],
    languageOptions: {
      globals: globals.browser,
      parserOptions: { ecmaFeatures: { jsx: true } },
    },
  },
])
__CIB_EOF_9f3a__
echo "  wrote frontend/eslint.config.js"

mkdir -p "frontend/src"
cat > "frontend/src/main.jsx" <<'__CIB_EOF_9f3a__'
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { ReactFlowProvider } from "@xyflow/react";
import App from "./App.jsx";
import "@xyflow/react/dist/style.css";
import "./index.css";

createRoot(document.getElementById("root")).render(
  <StrictMode>
    <ReactFlowProvider>
      <App />
    </ReactFlowProvider>
  </StrictMode>
);
__CIB_EOF_9f3a__
echo "  wrote frontend/src/main.jsx"

mkdir -p "frontend/src"
cat > "frontend/src/index.css" <<'__CIB_EOF_9f3a__'
@tailwind base;
@tailwind components;
@tailwind utilities;

/* React Flow's own stylesheet is imported in main.jsx (before this file). */

:root {
  color-scheme: dark;
}

html,
body,
#root {
  height: 100%;
  margin: 0;
}

body {
  background: #0a0c10;
  color: #e6e9ef;
  font-family: "Archivo", system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
}

/* ── React Flow overrides so it matches the blueprint theme ───────────── */
.react-flow {
  background:
    radial-gradient(circle at 50% 0%, rgba(255, 122, 24, 0.06), transparent 60%),
    #0a0c10;
}

.react-flow__edge-path {
  stroke: #3a4150;
  stroke-width: 1.5;
}
.react-flow__edge.selected .react-flow__edge-path,
.react-flow__edge:hover .react-flow__edge-path {
  stroke: #ff7a18;
}

.react-flow__handle {
  width: 9px;
  height: 9px;
  background: #0a0c10;
  border: 1.5px solid #5b6472;
  border-radius: 9999px;
}
.react-flow__handle:hover {
  border-color: #ff7a18;
  box-shadow: 0 0 0 3px rgba(255, 122, 24, 0.18);
}

.react-flow__controls {
  border: 1px solid #272d39;
  border-radius: 10px;
  overflow: hidden;
  box-shadow: none;
}
.react-flow__controls-button {
  background: #161a21;
  border-bottom: 1px solid #272d39;
  color: #aab2c0;
  fill: #aab2c0;
}
.react-flow__controls-button:hover {
  background: #1d222b;
}

.react-flow__minimap {
  background: #0f1217;
  border: 1px solid #272d39;
  border-radius: 10px;
}

.react-flow__attribution {
  background: transparent;
  color: #3a4150;
}

/* thin custom scrollbars for the panels */
.thin-scroll::-webkit-scrollbar {
  width: 8px;
}
.thin-scroll::-webkit-scrollbar-thumb {
  background: #272d39;
  border-radius: 8px;
}
__CIB_EOF_9f3a__
echo "  wrote frontend/src/index.css"

mkdir -p "frontend/src"
cat > "frontend/src/api.js" <<'__CIB_EOF_9f3a__'
// api.js — thin client for the FastAPI backend.

const BASE = import.meta.env.VITE_API_BASE || "http://localhost:8000";

// FastAPI returns errors in `detail`. For 422s that's an ARRAY of
// { loc, msg, type } objects; for our explicit HTTPExceptions it's a string.
// Without this, `new Error(detail)` stringifies the array to
// "[object Object],[object Object]…".
function formatError(json, status) {
  const d = json?.detail ?? json?.message;
  if (typeof d === "string") return d;
  if (Array.isArray(d)) {
    return d
      .map((e) => {
        const loc = Array.isArray(e.loc) ? e.loc.filter((p) => p !== "body").join(" › ") : "";
        return loc ? `${loc}: ${e.msg}` : e.msg;
      })
      .join("\n");
  }
  if (d && typeof d === "object") return JSON.stringify(d, null, 2);
  return `Request failed (${status})`;
}

async function post(path, body) {
  let res;
  try {
    res = await fetch(`${BASE}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch {
    throw new Error(`Cannot reach the API at ${BASE}. Is the backend running?`);
  }

  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { detail: text };
  }

  if (!res.ok) throw new Error(formatError(json, res.status));
  return json;
}

export const compilePreview = (payload) => post("/api/compile", payload);
export const runPipeline = (payload) => post("/api/run", payload);
__CIB_EOF_9f3a__
echo "  wrote frontend/src/api.js"

mkdir -p "frontend/src"
cat > "frontend/src/App.jsx" <<'__CIB_EOF_9f3a__'
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
__CIB_EOF_9f3a__
echo "  wrote frontend/src/App.jsx"

mkdir -p "frontend/src/pipeline"
cat > "frontend/src/pipeline/nodeCatalog.js" <<'__CIB_EOF_9f3a__'
// nodeCatalog.js
// Single source of truth for node types. Drives the palette, the node renderer,
// and the dynamic ConfigPanel.
//
// Field kinds the ConfigPanel knows how to render:
//   text · number · select · toggle · multiselect · chips · keyvalue ·
//   secretlist · testcases · actionWith · jobNeeds
// Any field may carry showIf(data) to render conditionally.

export const ASSERTIONS = [
  { value: "contains_text", label: "Page contains text" },
  { value: "element_visible", label: "Element is visible" },
  { value: "status_code", label: "Status code is" },
  { value: "url_contains", label: "URL contains" },
];

export const FRAMEWORKS = [
  { value: "playwright", label: "Playwright" },
  { value: "cypress", label: "Cypress" },
  { value: "jest", label: "Jest" },
  { value: "vitest", label: "Vitest" },
  { value: "bash", label: "Bash script" },
];

// Dynamic `with:` argument schemas for the Action node.
export const ACTION_SCHEMAS = {
  "actions/checkout@v4": [
    { key: "repository", label: "repository" },
    { key: "ref", label: "ref" },
    { key: "fetch-depth", label: "fetch-depth" },
    { key: "token", label: "token" },
  ],
  "actions/setup-node@v4": [
    { key: "node-version", label: "node-version" },
    { key: "cache", label: "cache (npm|yarn|pnpm)" },
    { key: "registry-url", label: "registry-url" },
  ],
  "actions/upload-artifact@v4": [
    { key: "name", label: "name" },
    { key: "path", label: "path" },
    { key: "retention-days", label: "retention-days" },
  ],
  "actions/download-artifact@v4": [
    { key: "name", label: "name" },
    { key: "path", label: "path" },
  ],
  "actions/cache@v4": [
    { key: "path", label: "path" },
    { key: "key", label: "key" },
  ],
  "actions/upload-pages-artifact@v3": [{ key: "path", label: "path" }],
  "actions/deploy-pages@v4": [],
};
export const ACTION_OPTIONS = Object.keys(ACTION_SCHEMAS).map((a) => ({ value: a, label: a }));

const OS_OPTIONS = [
  { value: "ubuntu-latest", label: "ubuntu-latest" },
  { value: "windows-latest", label: "windows-latest" },
  { value: "macos-latest", label: "macos-latest" },
];

export const NODE_CATALOG = {
  workflow: {
    type: "workflow",
    label: "Workflow",
    category: "workflow",
    icon: "⌗",
    blurb: "root · name:",
    defaults: { name: "CI Pipeline" },
    fields: [{ key: "name", label: "Workflow name", kind: "text" }],
  },

  event: {
    type: "event",
    label: "Event / Trigger",
    category: "event",
    icon: "⚡",
    blurb: "on:",
    defaults: { triggers: ["push"], push_branches: ["main"], pull_request_branches: [], cron: "" },
    fields: [
      {
        key: "triggers",
        label: "Trigger on",
        kind: "multiselect",
        options: [
          { value: "push", label: "push" },
          { value: "pull_request", label: "pull_request" },
          { value: "workflow_dispatch", label: "manual" },
          { value: "schedule", label: "schedule" },
        ],
      },
      {
        key: "push_branches",
        label: "Push branches",
        kind: "chips",
        showIf: (d) => d.triggers?.includes("push"),
      },
      {
        key: "pull_request_branches",
        label: "PR target branches",
        kind: "chips",
        showIf: (d) => d.triggers?.includes("pull_request"),
      },
      {
        key: "cron",
        label: "CRON expression",
        kind: "text",
        placeholder: "0 0 * * *",
        showIf: (d) => d.triggers?.includes("schedule"),
      },
    ],
  },

  job: {
    type: "job",
    label: "Job",
    category: "job",
    icon: "▤",
    blurb: "jobs.<id>",
    defaults: { jobId: "build", runsOn: "ubuntu-latest", timeoutMinutes: null, needs: [] },
    fields: [
      { key: "jobId", label: "Job ID", kind: "text" },
      { key: "runsOn", label: "Runner OS", kind: "select", options: OS_OPTIONS },
      { key: "timeoutMinutes", label: "Timeout (min)", kind: "number" },
      { key: "needs", label: "Depends on (needs)", kind: "jobNeeds" },
    ],
  },

  runner: {
    type: "runner",
    label: "Runner",
    category: "runner",
    icon: "◇",
    blurb: "runs-on",
    defaults: { hosted: true, image: "ubuntu-latest", labels: [] },
    fields: [
      { key: "hosted", label: "GitHub-hosted", kind: "toggle" },
      { key: "image", label: "Hosted image", kind: "select", options: OS_OPTIONS, showIf: (d) => d.hosted },
      { key: "labels", label: "Self-hosted labels", kind: "chips", showIf: (d) => !d.hosted },
    ],
  },

  step: {
    type: "step",
    label: "Step",
    category: "step",
    icon: "›",
    blurb: "run / uses",
    defaults: { name: "Step", mode: "run", run: "", uses: "", env: {} },
    fields: [
      { key: "name", label: "Step name", kind: "text" },
      {
        key: "mode",
        label: "Mode",
        kind: "select",
        options: [
          { value: "run", label: "Shell command (run:)" },
          { value: "uses", label: "Marketplace action (uses:)" },
        ],
      },
      { key: "run", label: "Command", kind: "textarea", showIf: (d) => d.mode === "run" },
      { key: "uses", label: "uses:", kind: "text", showIf: (d) => d.mode === "uses" },
      { key: "env", label: "Step env", kind: "keyvalue" },
    ],
  },

  action: {
    type: "action",
    label: "Action",
    category: "action",
    icon: "⊞",
    blurb: "uses: …",
    defaults: { name: "", action: "actions/checkout@v4", withArgs: {} },
    fields: [
      { key: "name", label: "Display name", kind: "text", placeholder: "(optional)" },
      { key: "action", label: "Action", kind: "select", options: ACTION_OPTIONS },
      { key: "withArgs", label: "with:", kind: "actionWith" },
    ],
  },

  secrets: {
    type: "secrets",
    label: "Secrets & Vars",
    category: "secrets",
    icon: "🔑",
    blurb: "env context",
    defaults: { secrets: [], vars: {} },
    fields: [
      { key: "secrets", label: "Required secrets", kind: "secretlist" },
      { key: "vars", label: "Plain variables", kind: "keyvalue" },
    ],
  },

  testsuite: {
    type: "testsuite",
    label: "Test Suite",
    category: "testsuite",
    icon: "✓",
    blurb: "framework + cases",
    defaults: { framework: "playwright", testcases: [] },
    fields: [
      { key: "framework", label: "Testing tech", kind: "select", options: FRAMEWORKS },
      { key: "testcases", label: "Testcases", kind: "testcases" },
    ],
  },
};

export const PALETTE = [
  "workflow", "event", "job", "runner", "step", "action", "secrets", "testsuite",
];

export const catColor = (category) =>
  ({
    workflow: "#ff7a18",
    event: "#fbbf24",
    job: "#38bdf8",
    runner: "#a78bfa",
    step: "#94a3b8",
    action: "#2dd4bf",
    secrets: "#f472b6",
    testsuite: "#34d399",
  })[category] || "#94a3b8";
__CIB_EOF_9f3a__
echo "  wrote frontend/src/pipeline/nodeCatalog.js"

mkdir -p "frontend/src/pipeline"
cat > "frontend/src/pipeline/PipelineNode.jsx" <<'__CIB_EOF_9f3a__'
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
__CIB_EOF_9f3a__
echo "  wrote frontend/src/pipeline/PipelineNode.jsx"

mkdir -p "frontend/src/pipeline"
cat > "frontend/src/pipeline/compilePayload.js" <<'__CIB_EOF_9f3a__'
// compilePayload.js — graph + form state → backend RunRequest.

export function buildRunPayload({ nodes, edges, repoUrl, token, branch, secrets }) {
  return {
    repo_url: repoUrl.trim(),
    access_token: token.trim(),
    branch: (branch || "main").trim(),
    nodes: nodes.map((n) => ({ id: n.id, type: n.type, data: n.data || {} })),
    edges: edges.map((e) => ({ id: e.id, source: e.source, target: e.target })),
    secrets: Object.fromEntries(Object.entries(secrets).filter(([, v]) => v)),
    push_secrets: Object.values(secrets).some(Boolean),
  };
}

// Secret names declared by any Secrets node — these feed the Secrets modal hints.
export function requiredSecrets(nodes) {
  const names = new Set();
  for (const n of nodes) {
    if (n.type === "secrets") (n.data?.secrets || []).forEach((s) => names.add(s));
  }
  return [...names];
}
__CIB_EOF_9f3a__
echo "  wrote frontend/src/pipeline/compilePayload.js"

mkdir -p "frontend/src/components"
cat > "frontend/src/components/NodePalette.jsx" <<'__CIB_EOF_9f3a__'
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
__CIB_EOF_9f3a__
echo "  wrote frontend/src/components/NodePalette.jsx"

mkdir -p "frontend/src/components"
cat > "frontend/src/components/ConfigPanel.jsx" <<'__CIB_EOF_9f3a__'
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
__CIB_EOF_9f3a__
echo "  wrote frontend/src/components/ConfigPanel.jsx"

mkdir -p "frontend/src/components"
cat > "frontend/src/components/SecretsModal.jsx" <<'__CIB_EOF_9f3a__'
// SecretsModal.jsx
// Modal for entering repository secrets. Values live only in React state and
// are sent once to the backend, which encrypts + pushes them to GitHub. They
// are never persisted in the browser.

import { useState } from "react";

export default function SecretsModal({ open, secrets, required, onSave, onClose }) {
  const [draft, setDraft] = useState(secrets);
  const [reveal, setReveal] = useState({});

  if (!open) return null;

  // Union of required names (from graph) + any already-entered keys
  const names = [...new Set([...required, ...Object.keys(draft)])];

  const setVal = (k, v) => setDraft((d) => ({ ...d, [k]: v }));
  const addCustom = () => {
    const name = prompt("Secret name (e.g. NPM_TOKEN)");
    if (name) setDraft((d) => ({ ...d, [name.trim().toUpperCase()]: "" }));
  };

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/60 backdrop-blur-sm">
      <div className="w-[480px] max-w-[92vw] overflow-hidden rounded-2xl border border-ink-500 bg-ink-800 shadow-node">
        <div className="flex items-center justify-between border-b border-ink-500 px-5 py-4">
          <div>
            <h2 className="font-display text-base font-700 text-slate-100">Repository Secrets</h2>
            <p className="mt-0.5 font-mono text-[11px] text-slate-500">
              Encrypted & pushed to GitHub · never stored in the browser
            </p>
          </div>
          <button
            onClick={onClose}
            className="rounded-md px-2 py-1 font-mono text-xs text-slate-500 hover:bg-ink-600 hover:text-slate-200"
          >
            esc
          </button>
        </div>

        <div className="thin-scroll max-h-[55vh] space-y-3 overflow-y-auto p-5">
          {names.length === 0 && (
            <p className="font-mono text-[12px] text-slate-500">
              The current pipeline needs no secrets. Add a Vercel or AWS deploy node, or define a
              custom one below.
            </p>
          )}
          {names.map((name) => {
            const isRequired = required.includes(name);
            return (
              <label key={name} className="block">
                <span className="mb-1 flex items-center gap-2 font-mono text-[11px] text-slate-400">
                  {name}
                  {isRequired && (
                    <span className="rounded bg-signal/15 px-1.5 py-0.5 text-[10px] text-signal-soft">
                      required
                    </span>
                  )}
                </span>
                <div className="flex gap-2">
                  <input
                    type={reveal[name] ? "text" : "password"}
                    value={draft[name] ?? ""}
                    onChange={(e) => setVal(name, e.target.value)}
                    placeholder="•••••••••••"
                    className="w-full rounded-lg border border-ink-500 bg-ink-900 px-3 py-2 font-mono
                      text-[13px] text-slate-100 outline-none focus:border-signal"
                  />
                  <button
                    type="button"
                    onClick={() => setReveal((r) => ({ ...r, [name]: !r[name] }))}
                    className="rounded-lg border border-ink-500 px-3 font-mono text-[11px] text-slate-400 hover:bg-ink-600"
                  >
                    {reveal[name] ? "hide" : "show"}
                  </button>
                </div>
              </label>
            );
          })}
        </div>

        <div className="flex items-center justify-between gap-3 border-t border-ink-500 px-5 py-4">
          <button
            onClick={addCustom}
            className="font-mono text-[12px] text-slate-400 hover:text-signal"
          >
            + custom secret
          </button>
          <div className="flex gap-2">
            <button
              onClick={onClose}
              className="rounded-lg px-4 py-2 font-mono text-[12px] text-slate-400 hover:bg-ink-600"
            >
              Cancel
            </button>
            <button
              onClick={() => onSave(draft)}
              className="rounded-lg bg-signal px-4 py-2 font-mono text-[12px] font-600 text-ink-900 hover:bg-signal-soft"
            >
              Save secrets
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
__CIB_EOF_9f3a__
echo "  wrote frontend/src/components/SecretsModal.jsx"

mkdir -p "frontend/src/components/editors"
cat > "frontend/src/components/editors/ChipsInput.jsx" <<'__CIB_EOF_9f3a__'
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
__CIB_EOF_9f3a__
echo "  wrote frontend/src/components/editors/ChipsInput.jsx"

mkdir -p "frontend/src/components/editors"
cat > "frontend/src/components/editors/KeyValueEditor.jsx" <<'__CIB_EOF_9f3a__'
// KeyValueEditor.jsx — editable map. value: { [k]: v }
export default function KeyValueEditor({ value = {}, onChange, keyPlaceholder = "KEY", valPlaceholder = "value" }) {
  const rows = Object.entries(value);

  const setKey = (oldK, newK) => {
    const next = {};
    for (const [k, v] of rows) next[k === oldK ? newK : k] = v;
    onChange(next);
  };
  const setVal = (k, v) => onChange({ ...value, [k]: v });
  const remove = (k) => {
    const next = { ...value };
    delete next[k];
    onChange(next);
  };
  const add = () => {
    if (value[""] === undefined) onChange({ ...value, "": "" });
  };

  const inp =
    "rounded-md border border-ink-500 bg-ink-900 px-2 py-1.5 font-mono text-[12px] text-slate-100 outline-none focus:border-signal";

  return (
    <div className="space-y-1.5">
      {rows.map(([k, v], i) => (
        <div key={i} className="flex items-center gap-1.5">
          <input className={`${inp} w-2/5`} value={k} placeholder={keyPlaceholder}
            onChange={(e) => setKey(k, e.target.value)} />
          <span className="font-mono text-slate-600">=</span>
          <input className={`${inp} flex-1`} value={v} placeholder={valPlaceholder}
            onChange={(e) => setVal(k, e.target.value)} />
          <button onClick={() => remove(k)} className="px-1.5 text-slate-500 hover:text-red-300">✕</button>
        </div>
      ))}
      <button onClick={add} className="font-mono text-[11px] text-slate-400 hover:text-signal">
        + add pair
      </button>
    </div>
  );
}
__CIB_EOF_9f3a__
echo "  wrote frontend/src/components/editors/KeyValueEditor.jsx"

mkdir -p "frontend/src/components/editors"
cat > "frontend/src/components/editors/MultiSelect.jsx" <<'__CIB_EOF_9f3a__'
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
__CIB_EOF_9f3a__
echo "  wrote frontend/src/components/editors/MultiSelect.jsx"

mkdir -p "frontend/src/components/editors"
cat > "frontend/src/components/editors/TestcaseManager.jsx" <<'__CIB_EOF_9f3a__'
// TestcaseManager.jsx — interactive list of testcases. value: TestCase[]
import { ASSERTIONS } from "../../pipeline/nodeCatalog";

const blank = () => ({ title: "", route: "/", assertion: "contains_text", expected: "" });

export default function TestcaseManager({ value = [], onChange }) {
  const update = (i, patch) =>
    onChange(value.map((tc, idx) => (idx === i ? { ...tc, ...patch } : tc)));
  const remove = (i) => onChange(value.filter((_, idx) => idx !== i));
  const add = () => onChange([...value, blank()]);

  const inp =
    "w-full rounded-md border border-ink-500 bg-ink-900 px-2 py-1.5 font-mono text-[12px] text-slate-100 outline-none focus:border-signal";
  const lbl = "mb-1 block font-mono text-[10px] uppercase tracking-wider text-slate-500";

  return (
    <div className="space-y-2.5">
      {value.map((tc, i) => (
        <div key={i} className="rounded-lg border border-ink-500 bg-ink-700/60 p-2.5">
          <div className="mb-2 flex items-center justify-between">
            <span className="font-mono text-[10px] text-slate-500">#{i + 1}</span>
            <button onClick={() => remove(i)} className="font-mono text-[11px] text-slate-500 hover:text-red-300">
              remove
            </button>
          </div>

          <label className={lbl}>Title</label>
          <input className={inp} value={tc.title} placeholder="Login page loads"
            onChange={(e) => update(i, { title: e.target.value })} />

          <div className="mt-2 grid grid-cols-2 gap-2">
            <div>
              <label className={lbl}>Route</label>
              <input className={inp} value={tc.route} placeholder="/login"
                onChange={(e) => update(i, { route: e.target.value })} />
            </div>
            <div>
              <label className={lbl}>Assertion</label>
              <select className={inp} value={tc.assertion}
                onChange={(e) => update(i, { assertion: e.target.value })}>
                {ASSERTIONS.map((a) => (
                  <option key={a.value} value={a.value}>{a.label}</option>
                ))}
              </select>
            </div>
          </div>

          <label className={`${lbl} mt-2`}>
            {tc.assertion === "element_visible" ? "Selector" :
             tc.assertion === "status_code" ? "Status code" :
             tc.assertion === "url_contains" ? "URL fragment" : "Expected text"}
          </label>
          <input className={inp} value={tc.expected}
            placeholder={tc.assertion === "status_code" ? "200" : tc.assertion === "element_visible" ? "#app" : "Sign in"}
            onChange={(e) => update(i, { expected: e.target.value })} />
        </div>
      ))}

      <button
        onClick={add}
        className="w-full rounded-lg border border-dashed border-ink-500 py-2 font-mono text-[12px] text-slate-400 hover:border-signal/60 hover:text-signal"
      >
        + Add testcase
      </button>
    </div>
  );
}
__CIB_EOF_9f3a__
echo "  wrote frontend/src/components/editors/TestcaseManager.jsx"

echo ""
echo "All files written. Next:"
echo "  cd frontend && npm install && npm run dev"
echo "  (separate terminal) cd backend && pip install -r requirements.txt && uvicorn api:app --reload --port 8000"