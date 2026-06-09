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
