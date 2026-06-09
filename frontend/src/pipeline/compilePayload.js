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
