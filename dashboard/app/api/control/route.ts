import { NextResponse } from "next/server";
import { authOK, getControl, setControl, type Control } from "@/lib/shared";

export const runtime = "edge";

// GET: the openring.sh loop polls this to learn if the user has queued a command.
// Requires the same bearer token as ingest.
export async function GET(req: Request) {
  if (!authOK(req)) return new NextResponse("unauthorized", { status: 401 });
  const c = (await getControl()) ?? { command: null, issued_at: 0 };
  return NextResponse.json(c);
}

// POST: the UI writes a command here. Same token.
const ALLOWED = new Set(["pause", "resume", "skip", "force-adversary", "stop", null]);

export async function POST(req: Request) {
  if (!authOK(req)) return new NextResponse("unauthorized", { status: 401 });

  const body = await req.json().catch(() => null) as { command?: string | null } | null;
  const cmd = body?.command ?? null;
  if (!ALLOWED.has(cmd as Control["command"])) {
    return new NextResponse("unknown command", { status: 400 });
  }

  const ctrl: Control = { command: cmd as Control["command"], issued_at: Date.now() };
  await setControl(ctrl);
  return NextResponse.json(ctrl);
}
