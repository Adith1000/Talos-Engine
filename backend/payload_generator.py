"""
payload_generator.py

Compiles a frontend node graph (DAG) into a valid GitHub Actions workflow,
and builds the /bin/sh script the Alpine container runs to inject + push it.

Public API
----------
compile_workflow(nodes, edges, *, testing_framework, deployment_target, secrets)
    -> str (the .github/workflows/ci.yml text)

generate_shell_script(repo_url, branch, container_clone_dir, ci_yml_content,
                      testing_framework)
    -> str (the /bin/sh script)

test_file_for(framework) -> (relative_path, content)

The original monolith hard-coded one workflow. Here every step block is a small
generator (generate_checkout_step, generate_playwright_steps, ...) and the
compiler walks the DAG in topological order, dispatching node.type -> generator.
"""

from __future__ import annotations

import textwrap
from collections import defaultdict, deque
from typing import Any


# ══════════════════════════════════════════════════════════════════════════════
#  Minimal YAML step emitter
#  We build steps as plain dicts and serialize by hand. PyYAML would wrap the
#  GitHub Actions "${{ ... }}" expressions in quotes and reorder keys, so a tiny
#  purpose-built emitter keeps the output clean and predictable.
# ══════════════════════════════════════════════════════════════════════════════

_STEP_BASE_INDENT = " " * 6   # steps live at: jobs > <job> > steps > "- name"
_KEY_INDENT = " " * 8         # keys under a step
_NESTED_INDENT = " " * 10     # keys under "with:" / "env:"


def _emit_step(step: dict[str, Any]) -> str:
    """Render one step dict to YAML lines. Recognised keys: name, uses, if, with, env, run."""
    lines: list[str] = []
    lines.append(f"{_STEP_BASE_INDENT}- name: {step['name']}")

    if step.get("if"):
        lines.append(f"{_KEY_INDENT}if: {step['if']}")

    if step.get("uses"):
        lines.append(f"{_KEY_INDENT}uses: {step['uses']}")

    for block_key in ("with", "env"):
        block = step.get(block_key)
        if block:
            lines.append(f"{_KEY_INDENT}{block_key}:")
            for k, v in block.items():
                lines.append(f"{_NESTED_INDENT}{k}: {v}")

    run = step.get("run")
    if run:
        run = run.strip("\n")
        if "\n" in run:
            lines.append(f"{_KEY_INDENT}run: |")
            body_indent = _KEY_INDENT + "  "
            for ln in run.split("\n"):
                lines.append(f"{body_indent}{ln}" if ln else "")
        else:
            lines.append(f"{_KEY_INDENT}run: {run}")

    return "\n".join(lines)


# ══════════════════════════════════════════════════════════════════════════════
#  Modular step generators — one per node type / variant
#  Each returns a list of step dicts (a node can expand to several steps).
# ══════════════════════════════════════════════════════════════════════════════

def generate_checkout_step(_cfg: dict) -> list[dict]:
    return [{"name": "Checkout repository", "uses": "actions/checkout@v4"}]


def generate_setup_node_step(cfg: dict) -> list[dict]:
    version = str(cfg.get("nodeVersion", "20"))
    return [{
        "name": "Setup Node.js",
        "uses": "actions/setup-node@v4",
        "with": {"node-version": version, "cache": "npm"},
    }]


def generate_install_step(cfg: dict) -> list[dict]:
    cmd = cfg.get("command") or "npm ci || npm install"
    return [{"name": "Install dependencies", "run": cmd}]


def generate_build_step(cfg: dict) -> list[dict]:
    cmd = cfg.get("command") or "npm run build --if-present"
    return [{"name": "Build", "run": cmd}]


# ── Testing frameworks ────────────────────────────────────────────────────────

def generate_playwright_steps(_cfg: dict) -> list[dict]:
    config_block = textwrap.dedent("""\
        cat << 'EOF' > playwright.config.ts
        import { defineConfig, devices } from '@playwright/test';
        export default defineConfig({
          testDir: './tests',
          fullyParallel: true,
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
        EOF""")
    return [
        {"name": "Install Playwright & browsers",
         "run": "npm install --no-save @playwright/test\nnpx playwright install --with-deps"},
        {"name": "Create Playwright config", "run": config_block},
        {"name": "Run Playwright tests", "run": "npx playwright test"},
        {"name": "Upload Playwright report",
         "if": "${{ always() }}",
         "uses": "actions/upload-artifact@v4",
         "with": {"name": "playwright-report", "path": "playwright-report/", "retention-days": 30}},
    ]


def generate_cypress_steps(_cfg: dict) -> list[dict]:
    return [
        {"name": "Install Cypress", "run": "npm install --no-save cypress"},
        {"name": "Run Cypress tests",
         "uses": "cypress-io/github-action@v6",
         "with": {"start": "npx vite --port 5173", "wait-on": "http://localhost:5173"}},
    ]


def generate_jest_steps(_cfg: dict) -> list[dict]:
    return [
        {"name": "Install Jest", "run": "npm install --no-save jest"},
        {"name": "Run Jest tests", "run": "npx jest --ci"},
    ]


def generate_vitest_steps(_cfg: dict) -> list[dict]:
    return [
        {"name": "Install Vitest", "run": "npm install --no-save vitest"},
        {"name": "Run Vitest", "run": "npx vitest run"},
    ]


_TEST_GENERATORS = {
    "playwright": generate_playwright_steps,
    "cypress": generate_cypress_steps,
    "jest": generate_jest_steps,
    "vitest": generate_vitest_steps,
}


def generate_test_steps(cfg: dict, default_framework: str) -> list[dict]:
    """A test node carries its own framework in cfg['framework']; falls back to the
    request-level default so the node and top-level field stay consistent."""
    fw = (cfg.get("framework") or default_framework or "none").lower()
    gen = _TEST_GENERATORS.get(fw)
    if not gen:
        return [{"name": f"Tests ({fw}) — no generator", "run": "echo 'No test framework configured'"}]
    return gen(cfg)


# ── Deploy targets ────────────────────────────────────────────────────────────

def generate_vercel_deploy(_cfg: dict) -> list[dict]:
    return [{
        "name": "Deploy to Vercel",
        "env": {
            "VERCEL_TOKEN": "${{ secrets.VERCEL_TOKEN }}",
            "VERCEL_ORG_ID": "${{ secrets.VERCEL_ORG_ID }}",
            "VERCEL_PROJECT_ID": "${{ secrets.VERCEL_PROJECT_ID }}",
        },
        "run": textwrap.dedent("""\
            npm i -g vercel
            vercel pull --yes --environment=production --token=$VERCEL_TOKEN
            vercel build --prod --token=$VERCEL_TOKEN
            vercel deploy --prebuilt --prod --token=$VERCEL_TOKEN"""),
    }]


def generate_github_pages_deploy(cfg: dict) -> list[dict]:
    publish_dir = cfg.get("publishDir") or "dist"
    return [
        {"name": "Upload Pages artifact",
         "uses": "actions/upload-pages-artifact@v3",
         "with": {"path": publish_dir}},
        {"name": "Deploy to GitHub Pages",
         "id": "deployment",
         "uses": "actions/deploy-pages@v4"},
    ]


def generate_aws_s3_deploy(cfg: dict) -> list[dict]:
    publish_dir = cfg.get("publishDir") or "dist"
    region = cfg.get("region") or "us-east-1"
    return [
        {"name": "Configure AWS credentials",
         "uses": "aws-actions/configure-aws-credentials@v4",
         "with": {
             "aws-access-key-id": "${{ secrets.AWS_ACCESS_KEY_ID }}",
             "aws-secret-access-key": "${{ secrets.AWS_SECRET_ACCESS_KEY }}",
             "aws-region": region,
         }},
        {"name": "Sync to S3",
         "run": f"aws s3 sync {publish_dir} s3://${{{{ secrets.AWS_S3_BUCKET }}}} --delete"},
    ]


_DEPLOY_GENERATORS = {
    "vercel": generate_vercel_deploy,
    "github-pages": generate_github_pages_deploy,
    "aws-s3": generate_aws_s3_deploy,
}


def generate_deploy_steps(cfg: dict, default_target: str) -> list[dict]:
    target = (cfg.get("target") or default_target or "none").lower()
    gen = _DEPLOY_GENERATORS.get(target)
    if not gen:
        return [{"name": f"Deploy ({target}) — no generator", "run": "echo 'No deploy target configured'"}]
    return gen(cfg)


# Dispatch table: node.type -> callable(cfg, *, defaults) -> list[step dict]
def _dispatch(node_type: str, cfg: dict, *, framework: str, target: str) -> list[dict]:
    table = {
        "checkout": lambda c: generate_checkout_step(c),
        "setup-node": lambda c: generate_setup_node_step(c),
        "install": lambda c: generate_install_step(c),
        "build": lambda c: generate_build_step(c),
        "test": lambda c: generate_test_steps(c, framework),
        "deploy": lambda c: generate_deploy_steps(c, target),
    }
    fn = table.get(node_type)
    if not fn:
        return [{"name": f"Unknown node '{node_type}'", "run": f"echo 'skipping unknown node {node_type}'"}]
    return fn(cfg)


# ══════════════════════════════════════════════════════════════════════════════
#  DAG ordering
# ══════════════════════════════════════════════════════════════════════════════

def _topological_order(nodes: list[dict], edges: list[dict]) -> list[dict]:
    """Kahn's algorithm. Ties are broken by the node's original index so the
    layout stays deterministic. Raises ValueError on a cycle."""
    by_id = {n["id"]: n for n in nodes}
    order_index = {n["id"]: i for i, n in enumerate(nodes)}

    indeg: dict[str, int] = {n["id"]: 0 for n in nodes}
    adj: dict[str, list[str]] = defaultdict(list)
    for e in edges:
        src, dst = e["source"], e["target"]
        if src in by_id and dst in by_id:
            adj[src].append(dst)
            indeg[dst] += 1

    # ready = nodes with no incoming edge, kept sorted by original index
    ready = deque(sorted((nid for nid, d in indeg.items() if d == 0),
                         key=lambda nid: order_index[nid]))
    ordered: list[dict] = []

    while ready:
        nid = ready.popleft()
        ordered.append(by_id[nid])
        for nxt in sorted(adj[nid], key=lambda x: order_index[x]):
            indeg[nxt] -= 1
            if indeg[nxt] == 0:
                ready.append(nxt)

    if len(ordered) != len(nodes):
        raise ValueError("Pipeline graph contains a cycle — cannot order steps.")
    return ordered


# ══════════════════════════════════════════════════════════════════════════════
#  Workflow compiler
# ══════════════════════════════════════════════════════════════════════════════

def compile_workflow(
    nodes: list[dict],
    edges: list[dict],
    *,
    testing_framework: str = "playwright",
    deployment_target: str = "vercel",
    secrets: dict[str, str] | None = None,
) -> str:
    """Translate the node graph into a complete GitHub Actions workflow string."""
    secrets = secrets or {}
    ordered = _topological_order(nodes, edges)

    # Does any node deploy to GitHub Pages? That requires job-level permissions.
    needs_pages = any(
        n.get("type") == "deploy"
        and (n.get("data", {}).get("target") or deployment_target) == "github-pages"
        for n in ordered
    )

    step_blocks: list[str] = []
    for node in ordered:
        cfg = node.get("data", {}) or {}
        for step in _dispatch(node["type"], cfg, framework=testing_framework, target=deployment_target):
            step_blocks.append(_emit_step(step))

    if not step_blocks:
        step_blocks.append(_emit_step(
            {"name": "Empty pipeline", "run": "echo 'No steps configured'"}))

    permissions = ""
    if needs_pages:
        permissions = textwrap.dedent("""\
            permissions:
              contents: read
              pages: write
              id-token: write
        """)

    header = textwrap.dedent("""\
        name: CI Pipeline (generated)

        on:
          push:
            branches: [main, master]
          workflow_dispatch:

        """)

    job = (
        f"{permissions}"
        "jobs:\n"
        "  pipeline:\n"
        "    runs-on: ubuntu-latest\n"
        "    steps:\n"
    )

    return header + job + "\n".join(step_blocks) + "\n"


# ══════════════════════════════════════════════════════════════════════════════
#  Test fixture files (injected into the repo by the shell script)
# ══════════════════════════════════════════════════════════════════════════════

_PLAYWRIGHT_SPEC = textwrap.dedent("""\
    import { test, expect } from '@playwright/test';

    test('homepage loads', async ({ page }) => {
      await page.goto('http://localhost:5173');
      await expect(page).toHaveTitle(/.+/);
    });
""")

_CYPRESS_SPEC = textwrap.dedent("""\
    describe('Smoke test', () => {
      it('loads the homepage', () => {
        cy.visit('http://localhost:5173');
        cy.get('body').should('be.visible');
      });
    });
""")

_JEST_SPEC = textwrap.dedent("""\
    test('sanity', () => {
      expect(1 + 1).toBe(2);
    });
""")

_VITEST_SPEC = textwrap.dedent("""\
    import { test, expect } from 'vitest';

    test('sanity', () => {
      expect(1 + 1).toBe(2);
    });
""")


def test_file_for(framework: str) -> tuple[str, str]:
    """Return (relative_path, file_content) for the chosen framework's sample spec."""
    fw = (framework or "none").lower()
    mapping = {
        "playwright": ("tests/example.spec.ts", _PLAYWRIGHT_SPEC),
        "cypress": ("cypress/e2e/example.cy.js", _CYPRESS_SPEC),
        "jest": ("tests/example.test.js", _JEST_SPEC),
        "vitest": ("tests/example.test.js", _VITEST_SPEC),
    }
    return mapping.get(fw, ("tests/example.spec.ts", _PLAYWRIGHT_SPEC))


# ══════════════════════════════════════════════════════════════════════════════
#  Shell script builder (runs inside the Alpine container)
# ══════════════════════════════════════════════════════════════════════════════

def generate_shell_script(
    repo_url: str,
    branch: str,
    container_clone_dir: str,
    ci_yml_content: str,
    testing_framework: str = "playwright",
) -> str:
    """Build the /bin/sh script that clones the repo, writes the workflow + the
    framework-appropriate test file, commits, and pushes."""
    safe_ci_yml = ci_yml_content.rstrip()
    test_path, test_content = test_file_for(testing_framework)
    safe_test = test_content.strip()
    test_dir = test_path.rsplit("/", 1)[0] if "/" in test_path else "."

    script = textwrap.dedent(f"""\
        set -euo pipefail
        export GIT_TERMINAL_PROMPT=0

        REPO_URL="{repo_url}"
        CLONE_DIR="{container_clone_dir}"
        BRANCH="{branch}"

        repo_path="${{REPO_URL#https://github.com/}}"
        if [ -z "$repo_path" ]; then
          echo "Invalid REPO_URL: $REPO_URL" >&2
          exit 2
        fi
        case "$repo_path" in
          *.git) auth_path="$repo_path" ;;
          *) auth_path="${{repo_path}}.git" ;;
        esac

        AUTH_URL="https://x-access-token:$GIT_TOKEN@github.com/$auth_path"

        echo ">>> cloning $REPO_URL into $CLONE_DIR"
        git clone "$AUTH_URL" "$CLONE_DIR" || {{ echo "clone failed"; exit 3; }}
        cd "$CLONE_DIR"

        if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
          git checkout "$BRANCH"
        else
          git checkout -b "$BRANCH"
        fi

        # strip the token back out of the stored remote
        git remote set-url origin "https://github.com/$auth_path"

        mkdir -p .github/workflows
        mkdir -p {test_dir}

        cat > {test_path} <<'TEST'
        {safe_test}
        TEST

        cat > .github/workflows/ci.yml <<'YML'
        {safe_ci_yml}
        YML

        echo ">>> files present:"
        ls -la .github/workflows || true
        ls -la {test_dir} || true

        git add .github/workflows/ci.yml {test_path}

        echo ">>> staged files:"
        git diff --cached --name-only || true

        if git diff --cached --quiet; then
          echo ">>> No changes to commit. Skipping."
        else
          echo ">>> committing with inline identity..."
          git -c user.name="CI Bot (container)" -c user.email="ci-bot@example.com" \\
              commit -m "Add generated CI workflow + {testing_framework} test" || {{ echo "commit failed"; exit 4; }}

          echo ">>> commit created:"
          git log -n 3 --oneline

          echo ">>> pushing to remote..."
          git push "https://x-access-token:$GIT_TOKEN@github.com/$auth_path" "HEAD:$BRANCH" || {{ echo "push failed"; exit 5; }}
          echo ">>> push succeeded"
        fi

        echo ">>> final remote HEAD (verify):"
        git ls-remote "https://x-access-token:$GIT_TOKEN@github.com/$auth_path" HEAD || true

        echo "Container job complete."
    """)
    return script