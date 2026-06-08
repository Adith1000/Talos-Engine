// api.js — thin client for the FastAPI backend.

const BASE = import.meta.env.VITE_API_BASE || "http://localhost:8000";

async function post(path, body) {
  const res = await fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { detail: text };
  }
  if (!res.ok) {
    throw new Error(json.detail || `Request failed (${res.status})`);
  }
  return json;
}

export const compilePreview = (payload) => post("/api/compile", payload);
export const runPipeline = (payload) => post("/api/run", payload);