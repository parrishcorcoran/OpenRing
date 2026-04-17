import { NextResponse } from "next/server";
import { authOK, setTail, redact, MAX_TAIL_LINES, MAX_TAIL_BYTES, type Tail } from "@/lib/shared";

export const runtime = "edge";

export async function POST(req: Request) {
  if (!authOK(req)) return new NextResponse("unauthorized", { status: 401 });

  const body = await req.json().catch(() => null) as Partial<Tail> | null;
  if (!body || typeof body.cycle !== "number" || !Array.isArray(body.lines)) {
    return new NextResponse("bad request", { status: 400 });
  }

  // Redact, cap line count, cap total byte size.
  let bytes = 0;
  const safe: string[] = [];
  for (const raw of body.lines.slice(-MAX_TAIL_LINES)) {
    const line = redact(String(raw));
    const lineBytes = Buffer.byteLength(line, "utf8") + 1;
    if (bytes + lineBytes > MAX_TAIL_BYTES) break;
    bytes += lineBytes;
    safe.push(line);
  }

  const tail: Tail = {
    cycle: body.cycle,
    role: String(body.role ?? ""),
    lines: safe,
    updated_at: Date.now(),
  };

  await setTail(tail);
  return NextResponse.json({ ok: true, kept: safe.length });
}
