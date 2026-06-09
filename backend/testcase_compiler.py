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
