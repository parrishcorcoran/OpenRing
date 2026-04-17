import { kv } from "@vercel/kv";

export type Status = {
  cycle: number;
  role: "architect" | "adversary" | "grinder" | string;
  model: string;
  last_commit_sha: string | null;
  stall_count: number;
  tree_clean: boolean;
  updated_at: number;
};

export type Control = {
  command: "pause" | "resume" | "skip" | "force-adversary" | "stop" | null;
  issued_at: number;
};

export type Tail = {
  cycle: number;
  role: string;
  lines: string[];
  updated_at: number;
};

export type Whiteboard = {
  content: string;
  updated_at: number;
  source: "dashboard" | "loop";
};

const K = {
  status: "ring:status",
  control: "ring:control",
  tail: "ring:tail",
  whiteboard: "ring:whiteboard",
};

export const getStatus = () => kv.get<Status>(K.status);
export const setStatus = (s: Status) => kv.set(K.status, s);

export const getControl = () => kv.get<Control>(K.control);
export const setControl = (c: Control) => kv.set(K.control, c);

export const getTail = () => kv.get<Tail>(K.tail);
export const setTail = (t: Tail) => kv.set(K.tail, t, { ex: 60 * 60 });

export const getWhiteboard = () => kv.get<Whiteboard>(K.whiteboard);
export const setWhiteboard = (w: Whiteboard) => kv.set(K.whiteboard, w);

export function authOK(req: Request): boolean {
  const expected = process.env.OPENRING_TOKEN;
  if (!expected) return false;
  const header = req.headers.get("authorization") || "";
  const m = header.match(/^Bearer\s+(.+)$/i);
  return !!m && m[1].trim() === expected;
}

// Scrub common credential shapes before anything is written to KV or rendered.
// This runs on *every* line of the tail — both for ingest and before display.
const PATTERNS: Array<[RegExp, string]> = [
  [/sk-(?:ant-)?[A-Za-z0-9_-]{20,}/g, "[REDACTED:anthropic-or-openai-key]"],
  [/gh[pousr]_[A-Za-z0-9]{30,}/g, "[REDACTED:github-token]"],
  [/AIza[0-9A-Za-z_-]{30,}/g, "[REDACTED:google-api-key]"],
  [/xox[baprs]-[A-Za-z0-9-]{10,}/g, "[REDACTED:slack-token]"],
  [/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, "[REDACTED:jwt]"],
  [/-----BEGIN[^-]+PRIVATE KEY-----[\s\S]*?-----END[^-]+PRIVATE KEY-----/g, "[REDACTED:private-key]"],
  [/\b(password|passwd|secret|api[_-]?key|token)\s*[:=]\s*[^\s"'`]+/gi, "$1=[REDACTED]"],
  // Long continuous base64-ish (≥40 chars) that doesn't have obvious word boundaries.
  [/\b[A-Za-z0-9+/]{40,}={0,2}\b/g, "[REDACTED:long-b64]"],
];

export function redact(s: string): string {
  let out = s;
  for (const [re, sub] of PATTERNS) out = out.replace(re, sub);
  return out;
}

export const MAX_TAIL_LINES = 80;
export const MAX_TAIL_BYTES = 16 * 1024;
