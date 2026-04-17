import { NextResponse } from "next/server";
import { authOK, getWhiteboard, setWhiteboard, type Whiteboard } from "@/lib/shared";

export const runtime = "edge";

const MAX_CONTENT_BYTES = 8 * 1024;

// GET: loop polls this at cycle start (and UI reads it for display).
export async function GET(req: Request) {
  if (!authOK(req)) return new NextResponse("unauthorized", { status: 401 });
  const w = (await getWhiteboard()) ?? { content: "", updated_at: 0, source: "dashboard" as const };
  return NextResponse.json(w);
}

// POST: dashboard UI or loop syncs new content.
export async function POST(req: Request) {
  if (!authOK(req)) return new NextResponse("unauthorized", { status: 401 });

  const body = await req.json().catch(() => null) as Partial<Whiteboard> | null;
  if (!body || typeof body.content !== "string") {
    return new NextResponse("bad request", { status: 400 });
  }

  if (Buffer.byteLength(body.content, "utf8") > MAX_CONTENT_BYTES) {
    return new NextResponse("whiteboard too large", { status: 413 });
  }

  const source: Whiteboard["source"] = body.source === "loop" ? "loop" : "dashboard";
  const w: Whiteboard = { content: body.content, updated_at: Date.now(), source };
  await setWhiteboard(w);
  return NextResponse.json(w);
}
