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
