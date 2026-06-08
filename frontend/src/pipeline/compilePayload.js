// compilePayload.js
// Converts the React Flow graph + form state into the JSON the backend expects.

export function buildRunPayload({ nodes, edges, repoUrl, token, branch, secrets }) {
  // Derive top-level framework/target from whichever node carries them (the
  // backend treats these as defaults; nodes still win individually).
  const testNode = nodes.find((n) => n.type === "test");
  const deployNode = nodes.find((n) => n.type === "deploy");

  return {
    repo_url: repoUrl.trim(),
    access_token: token.trim(),
    branch: branch.trim() || "main",
    nodes: nodes.map((n) => ({ id: n.id, type: n.type, data: n.data || {} })),
    edges: edges.map((e) => ({ id: e.id, source: e.source, target: e.target })),
    testing_framework: testNode?.data?.framework || "playwright",
    deployment_target: deployNode?.data?.target || "vercel",
    secrets: Object.fromEntries(
      Object.entries(secrets).filter(([, v]) => v && v.length > 0)
    ),
    push_secrets: Object.keys(secrets).length > 0,
  };
}

// Which secret names the current graph requires, for the secrets modal hints.
import { TARGET_SECRETS } from "./nodeCatalog";

export function requiredSecrets(nodes) {
  const names = new Set();
  for (const n of nodes) {
    if (n.type === "deploy") {
      const target = n.data?.target || "vercel";
      (TARGET_SECRETS[target] || []).forEach((s) => names.add(s));
    }
  }
  return [...names];
}