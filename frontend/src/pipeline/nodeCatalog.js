// nodeCatalog.js
// Single source of truth for the node types. Drives the palette, the custom
// node renderer, and the dynamically generated config panel.
//
// Each entry:
//   type      – stable id sent to the backend (must match payload_generator dispatch)
//   label     – display name
//   category  – tailwind "cat.*" color key
//   icon      – short glyph shown on the node
//   fields    – config schema; each field renders an input in ConfigPanel
//   defaults  – initial data object for a freshly dropped node
//
// Field kinds: "text", "select" (needs options), "toggle"

export const FRAMEWORK_OPTIONS = [
  { value: "playwright", label: "Playwright" },
  { value: "cypress", label: "Cypress" },
  { value: "jest", label: "Jest" },
  { value: "vitest", label: "Vitest" },
];

export const DEPLOY_OPTIONS = [
  { value: "vercel", label: "Vercel" },
  { value: "github-pages", label: "GitHub Pages" },
  { value: "aws-s3", label: "AWS S3" },
];

// Which secrets each deploy target needs (mirrors backend config.TARGET_SECRETS)
export const TARGET_SECRETS = {
  vercel: ["VERCEL_TOKEN", "VERCEL_ORG_ID", "VERCEL_PROJECT_ID"],
  "github-pages": [],
  "aws-s3": ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_S3_BUCKET"],
};

export const NODE_CATALOG = {
  checkout: {
    type: "checkout",
    label: "Checkout Repo",
    category: "checkout",
    icon: "⎇",
    blurb: "actions/checkout@v4",
    fields: [],
    defaults: {},
  },
  "setup-node": {
    type: "setup-node",
    label: "Setup Node",
    category: "setup",
    icon: "▲",
    blurb: "actions/setup-node@v4",
    fields: [
      {
        key: "nodeVersion",
        label: "Node version",
        kind: "select",
        options: [
          { value: "18", label: "18.x" },
          { value: "20", label: "20.x" },
          { value: "22", label: "22.x" },
        ],
      },
    ],
    defaults: { nodeVersion: "20" },
  },
  install: {
    type: "install",
    label: "Install Deps",
    category: "install",
    icon: "↓",
    blurb: "npm ci",
    fields: [{ key: "command", label: "Install command", kind: "text" }],
    defaults: { command: "npm ci || npm install" },
  },
  test: {
    type: "test",
    label: "Run Tests",
    category: "test",
    icon: "✓",
    blurb: "test runner",
    fields: [
      { key: "framework", label: "Framework", kind: "select", options: FRAMEWORK_OPTIONS },
    ],
    defaults: { framework: "playwright" },
  },
  build: {
    type: "build",
    label: "Build",
    category: "build",
    icon: "⚙",
    blurb: "npm run build",
    fields: [{ key: "command", label: "Build command", kind: "text" }],
    defaults: { command: "npm run build --if-present" },
  },
  deploy: {
    type: "deploy",
    label: "Deploy",
    category: "deploy",
    icon: "↑",
    blurb: "ship it",
    fields: [
      { key: "target", label: "Target", kind: "select", options: DEPLOY_OPTIONS },
      {
        key: "publishDir",
        label: "Publish dir",
        kind: "text",
        showIf: (d) => d.target === "github-pages" || d.target === "aws-s3",
      },
      {
        key: "region",
        label: "AWS region",
        kind: "text",
        showIf: (d) => d.target === "aws-s3",
      },
    ],
    defaults: { target: "vercel", publishDir: "dist", region: "us-east-1" },
  },
};

// Palette order
export const PALETTE = ["checkout", "setup-node", "install", "test", "build", "deploy"];

export const catColor = (category) =>
  ({
    checkout: "#38bdf8",
    setup: "#a78bfa",
    install: "#2dd4bf",
    test: "#f5a524",
    build: "#94a3b8",
    deploy: "#34d399",
  })[category] || "#94a3b8";