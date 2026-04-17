import { NextResponse } from "next/server";
import { authOK, getStatus, getTail, getWhiteboard } from "@/lib/shared";

export const runtime = "edge";

// Read endpoint used by the UI. Same bearer token as ingest.
export async function GET(req: Request) {
  if (!authOK(req)) return new NextResponse("unauthorized", { status: 401 });

  const [status, tail, whiteboard] = await Promise.all([getStatus(), getTail(), getWhiteboard()]);
  return NextResponse.json({ status, tail, whiteboard });
}
