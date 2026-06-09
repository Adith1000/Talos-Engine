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
