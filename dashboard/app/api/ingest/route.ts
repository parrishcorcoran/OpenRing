import { NextResponse } from "next/server";
import { authOK, setStatus, type Status } from "@/lib/shared";

export const runtime = "edge";

export async function POST(req: Request) {
  if (!authOK(req)) return new NextResponse("unauthorized", { status: 401 });

  const body = await req.json().catch(() => null) as Partial<Status> | null;
  if (!body || typeof body.cycle !== "number" || !body.role || !body.model) {
    return new NextResponse("bad request", { status: 400 });
  }

  const status: Status = {
    cycle: body.cycle,
    role: String(body.role),
    model: String(body.model),
    last_commit_sha: body.last_commit_sha ? String(body.last_commit_sha) : null,
    stall_count: typeof body.stall_count === "number" ? body.stall_count : 0,
    tree_clean: !!body.tree_clean,
    updated_at: Date.now(),
  };

  await setStatus(status);
  return NextResponse.json({ ok: true });
}
