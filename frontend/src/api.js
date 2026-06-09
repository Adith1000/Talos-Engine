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
