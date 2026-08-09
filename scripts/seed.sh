#!/bin/bash
# Seed a Langfuse project with sample traces so the wrapper has something to read.
#
# Usage:
#   export LANGFUSE_PUBLIC_KEY=pk-lf-...
#   export LANGFUSE_SECRET_KEY=sk-lf-...
#   export LANGFUSE_HOST=https://jp.cloud.langfuse.com   # jp / us / eu (cloud.langfuse.com)
#   ./scripts/seed.sh

set -euo pipefail

: "${LANGFUSE_PUBLIC_KEY:?set LANGFUSE_PUBLIC_KEY}"
: "${LANGFUSE_SECRET_KEY:?set LANGFUSE_SECRET_KEY}"
HOST="${LANGFUSE_HOST:-https://jp.cloud.langfuse.com}"

# Three users on different plans, so `join ... group by plan` has something to show.
# Costs are deliberately uneven to make aggregates easy to eyeball.
build_batch() {
  python3 - <<'PY'
import json, uuid, datetime, sys

now = datetime.datetime.now(datetime.timezone.utc)
rows = [
    # (user, model, in_tok, out_tok, in_cost, out_cost, latency_s, minutes_ago, name)
    ("user-alice", "claude-opus-5",     1200,  340, 0.0180, 0.0255,  4.2,   5, "summarize-doc"),
    ("user-alice", "claude-opus-5",      890,  210, 0.0134, 0.0158,  2.8,  40, "summarize-doc"),
    ("user-bob",   "claude-sonnet-5",   4300, 1100, 0.0129, 0.0165,  6.1,  70, "chat-turn"),
    ("user-bob",   "claude-sonnet-5",    620,  180, 0.0019, 0.0027,  1.4, 130, "chat-turn"),
    ("user-bob",   "claude-haiku-4-5",   310,   95, 0.0002, 0.0004,  0.7, 190, "classify"),
    ("user-carol", "claude-haiku-4-5",   180,   60, 0.0001, 0.0002,  0.5, 260, "classify"),
]

batch = []
for i, (user, model, itok, otok, icost, ocost, latency, mins, name) in enumerate(rows):
    trace_id = str(uuid.uuid4())
    start = now - datetime.timedelta(minutes=mins)
    end = start + datetime.timedelta(seconds=latency)

    batch.append({
        "type": "trace-create",
        "id": str(uuid.uuid4()),
        "timestamp": now.isoformat(),
        "body": {
            "id": trace_id,
            "name": name,
            "userId": user,
            "sessionId": f"session-{i // 2}",
            "timestamp": start.isoformat(),
            "tags": ["seed"],
            "environment": "default",
        },
    })
    batch.append({
        "type": "generation-create",
        "id": str(uuid.uuid4()),
        "timestamp": now.isoformat(),
        "body": {
            "id": str(uuid.uuid4()),
            "traceId": trace_id,
            "name": name,
            "startTime": start.isoformat(),
            "endTime": end.isoformat(),
            "completionStartTime": (start + datetime.timedelta(seconds=latency / 3)).isoformat(),
            "model": model,
            "modelParameters": {"temperature": 0.7, "max_tokens": 1024},
            "input": f"[seed] prompt for {name} from {user}",
            "output": f"[seed] completion for {name}",
            "metadata": {"seeded": True, "plan_hint": user.split("-")[1]},
            "usageDetails": {"input": itok, "output": otok, "total": itok + otok},
            "costDetails": {"input": icost, "output": ocost, "total": round(icost + ocost, 6)},
            "level": "DEFAULT",
            "environment": "default",
        },
    })

json.dump({"batch": batch}, sys.stdout)
PY
}

echo "Seeding ${HOST} ..."
resp=$(build_batch | curl -sS -w '\n%{http_code}' \
  -u "${LANGFUSE_PUBLIC_KEY}:${LANGFUSE_SECRET_KEY}" \
  -H 'content-type: application/json' \
  -X POST "${HOST}/api/public/ingestion" \
  --data-binary @-)

code=$(printf '%s' "$resp" | tail -1)
body=$(printf '%s' "$resp" | sed '$d')

# Ingestion answers 207 with a per-event error list rather than a 4xx.
echo "HTTP ${code}"
printf '%s\n' "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(sys.stdin.read()); sys.exit(0)
ok, errs = d.get("successes", []), d.get("errors", [])
print(f"accepted: {len(ok)}  errors: {len(errs)}")
for e in errs[:5]:
    print("  !", json.dumps(e))
'

echo
echo "Done. Traces take a few seconds to become queryable."
