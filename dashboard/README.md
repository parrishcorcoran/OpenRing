# OpenRing Dashboard (Vercel)

A tiny Next.js app that gives you a read-only peek at a running OpenRing loop from anywhere, plus a minimal remote-control surface (pause / resume / skip / force-adversary / stop).

## What it stores

Only **metadata** from each cycle:
- cycle number
- role (architect / adversary / grinder)
- model name
- last commit SHA
- stall count
- tree-clean flag
- a truncated, **redacted** tail of the last agent's output (last ≤80 lines, ≤16KB, with common credential shapes scrubbed)

Actual diffs and source don't cross the wire. If you want to read the code your Ring produced from your phone, open GitHub.

## Deploy

1. Create a new project on Vercel pointing at this `dashboard/` directory.
2. Add **Vercel KV** (Upstash Redis) to the project — it auto-populates the `KV_*` env vars.
3. Add an env var `OPENRING_TOKEN` with a long random string (`openssl rand -hex 32`). This is the bearer token both openring.sh and the UI will use.
4. Deploy.

## Point openring.sh at it

On the machine running the Ring:

```bash
export OPENRING_DASHBOARD_URL="https://your-project.vercel.app"
export OPENRING_DASHBOARD_TOKEN="<same value as Vercel OPENRING_TOKEN>"
openring
```

Then open your Vercel URL on any device, paste the same token, and watch.

## Endpoints

- `POST /api/ingest` — loop posts cycle metadata. Bearer auth.
- `POST /api/tail` — loop posts last N lines of cycle log (redacted server-side too). Bearer auth.
- `GET  /api/control` — loop polls for pending command (pause / skip / ...). Bearer auth.
- `POST /api/control` — UI sets a command. Bearer auth.
- `GET  /api/status` — UI reads current status + tail. Bearer auth.

## Safety notes

- **Token leak scope:** an attacker with the token can read cycle metadata + the truncated tail, and can send control commands (stop/pause/force-adversary). They cannot read your source, your diffs, or your commit contents. They cannot trigger arbitrary agent actions.
- **Redaction is belt-and-suspenders.** The openring.sh side strips obvious secrets before sending; the server strips them again before storing; the UI just displays what's in KV. Don't rely on any single layer.
- **Rotate the token** by updating the Vercel env var and your local env var. There's no session state to invalidate.
