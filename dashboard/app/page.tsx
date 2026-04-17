"use client";

import { useEffect, useState, useCallback } from "react";

type Status = {
  cycle: number;
  role: string;
  model: string;
  last_commit_sha: string | null;
  stall_count: number;
  tree_clean: boolean;
  updated_at: number;
} | null;

type Tail = { cycle: number; role: string; lines: string[]; updated_at: number } | null;
type Whiteboard = { content: string; updated_at: number; source: "dashboard" | "loop" } | null;

const POLL_MS = 3000;
const STALE_MS = 5 * 60 * 1000;

function tokenKey() { return "openring_token"; }

export default function Page() {
  const [token, setToken] = useState<string>("");
  const [entered, setEntered] = useState(false);
  const [status, setStatus] = useState<Status>(null);
  const [tail, setTail] = useState<Tail>(null);
  const [whiteboard, setWhiteboard] = useState<Whiteboard>(null);
  const [draft, setDraft] = useState<string>("");
  const [dirty, setDirty] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const t = typeof window !== "undefined" ? localStorage.getItem(tokenKey()) : null;
    if (t) { setToken(t); setEntered(true); }
  }, []);

  const fetchStatus = useCallback(async () => {
    if (!token) return;
    try {
      const r = await fetch("/api/status", { headers: { authorization: `Bearer ${token}` }, cache: "no-store" });
      if (r.status === 401) { setError("unauthorized — check your token"); return; }
      if (!r.ok) { setError(`fetch failed: ${r.status}`); return; }
      const j = await r.json();
      setStatus(j.status);
      setTail(j.tail);
      setWhiteboard(j.whiteboard);
      if (!dirty) setDraft(j.whiteboard?.content ?? "");
      setError(null);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [token, dirty]);

  useEffect(() => {
    if (!entered) return;
    fetchStatus();
    const id = setInterval(fetchStatus, POLL_MS);
    return () => clearInterval(id);
  }, [entered, fetchStatus]);

  const sendCommand = async (command: string | null) => {
    if (!token) return;
    await fetch("/api/control", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ command }),
    });
    fetchStatus();
  };

  const saveWhiteboard = async () => {
    if (!token) return;
    await fetch("/api/whiteboard", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ content: draft, source: "dashboard" }),
    });
    setDirty(false);
    fetchStatus();
  };

  if (!entered) {
    return (
      <main style={{ maxWidth: 480, margin: "10vh auto", padding: 24 }}>
        <h1 style={{ fontSize: 24, margin: 0 }}>⭕ OpenRing</h1>
        <p style={{ color: "#888" }}>Paste the bearer token that matches your Vercel <code>OPENRING_TOKEN</code> env var.</p>
        <input
          type="password"
          value={token}
          onChange={e => setToken(e.target.value)}
          style={{ width: "100%", padding: 12, background: "#1a1a1d", color: "#e6e6e6", border: "1px solid #333", fontFamily: "inherit" }}
          placeholder="bearer token"
        />
        <button
          onClick={() => { localStorage.setItem(tokenKey(), token); setEntered(true); }}
          style={{ marginTop: 12, padding: "10px 16px", background: "#2a6", color: "#000", border: 0, cursor: "pointer" }}
        >
          connect
        </button>
      </main>
    );
  }

  const ageMs = status ? Date.now() - status.updated_at : Infinity;
  const stale = ageMs > STALE_MS;
  const statusColor = !status ? "#888" : stale ? "#b33" : status.stall_count >= 2 ? "#b93" : "#2a6";

  return (
    <main style={{ maxWidth: 920, margin: "0 auto", padding: 24 }}>
      <header style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 16, flexWrap: "wrap" }}>
        <h1 style={{ fontSize: 20, margin: 0 }}>⭕ OpenRing <span style={{ color: "#666", fontWeight: 400 }}>— live peek</span></h1>
        <button onClick={() => { localStorage.removeItem(tokenKey()); setToken(""); setEntered(false); }} style={{ background: "transparent", color: "#888", border: "1px solid #333", padding: "4px 10px", cursor: "pointer" }}>
          sign out
        </button>
      </header>

      {error && <p style={{ color: "#f66" }}>{error}</p>}

      <section style={{ marginTop: 16, padding: 16, background: "#141417", border: "1px solid #222", borderRadius: 6 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
          <span style={{ width: 10, height: 10, borderRadius: 10, background: statusColor, display: "inline-block" }} />
          <strong style={{ fontSize: 16 }}>{status ? `cycle ${status.cycle}` : "no data yet"}</strong>
          {status && <span>· {status.role}</span>}
          {status && <span style={{ color: "#999" }}>· {status.model}</span>}
          {status && status.stall_count > 0 && <span style={{ color: "#b93" }}>· stall {status.stall_count}</span>}
          {status && <span style={{ color: "#666", marginLeft: "auto" }}>{humanAge(ageMs)} ago</span>}
        </div>
        {status?.last_commit_sha && <div style={{ color: "#999", marginTop: 6 }}>HEAD {status.last_commit_sha.slice(0, 10)}</div>}
      </section>

      <section style={{ marginTop: 16, display: "flex", gap: 8, flexWrap: "wrap" }}>
        <CmdButton label="pause" onClick={() => sendCommand("pause")} />
        <CmdButton label="resume" onClick={() => sendCommand("resume")} />
        <CmdButton label="skip next" onClick={() => sendCommand("skip")} />
        <CmdButton label="force adversary" onClick={() => sendCommand("force-adversary")} />
        <CmdButton label="stop after cycle" onClick={() => sendCommand("stop")} danger />
        <CmdButton label="clear" onClick={() => sendCommand(null)} />
      </section>

      <section style={{ marginTop: 20 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 10, flexWrap: "wrap" }}>
          <div style={{ color: "#ccc", fontSize: 13 }}>🪧 whiteboard <span style={{ color: "#666" }}>(Architect reads this next cycle)</span></div>
          <div style={{ color: "#666", fontSize: 12 }}>
            {whiteboard?.updated_at ? `last saved ${humanAge(Date.now() - whiteboard.updated_at)} ago by ${whiteboard.source}` : "empty"}
          </div>
        </div>
        <textarea
          value={draft}
          onChange={e => { setDraft(e.target.value); setDirty(true); }}
          placeholder="Drop the current objective. Fix the auth race condition in src/api/login.ts first."
          rows={6}
          style={{ width: "100%", marginTop: 6, padding: 12, background: "#0f0f11", color: "#e6e6e6", border: "1px solid #333", fontFamily: "inherit", fontSize: 13, lineHeight: 1.5, resize: "vertical", boxSizing: "border-box" }}
        />
        <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
          <CmdButton label={dirty ? "save whiteboard" : "saved"} onClick={saveWhiteboard} />
          {dirty && <CmdButton label="discard" onClick={() => { setDraft(whiteboard?.content ?? ""); setDirty(false); }} />}
        </div>
      </section>

      <section style={{ marginTop: 16 }}>
        <div style={{ color: "#888", fontSize: 12, marginBottom: 6 }}>
          tail — last {tail?.lines.length ?? 0} lines, redacted for secrets
        </div>
        <pre style={{ margin: 0, padding: 14, background: "#0f0f11", border: "1px solid #222", borderRadius: 6, maxHeight: "50vh", overflow: "auto", fontSize: 12, lineHeight: 1.45, whiteSpace: "pre-wrap" }}>
          {tail?.lines.join("\n") ?? "(no tail yet — openring.sh posts this after each agent run)"}
        </pre>
      </section>
    </main>
  );
}

function CmdButton({ label, onClick, danger }: { label: string; onClick: () => void; danger?: boolean }) {
  return (
    <button
      onClick={onClick}
      style={{
        padding: "8px 12px",
        background: danger ? "#331214" : "#1a1a1d",
        color: danger ? "#f88" : "#e6e6e6",
        border: "1px solid #333",
        cursor: "pointer",
        fontFamily: "inherit",
        fontSize: 13,
      }}
    >
      {label}
    </button>
  );
}

function humanAge(ms: number) {
  if (!isFinite(ms)) return "never";
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return `${h}h`;
}
