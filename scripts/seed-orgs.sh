#!/bin/bash
# Seed a Langfuse project with traces carrying *trace-level* metadata, so cost can be
# attributed to a business dimension the Langfuse UI cannot break down by.
#
# The original seed.sh puts metadata on the generation. The wrapper exposes `traces`, so
# trace-level metadata is what `metadata->>'organizationId'` actually reads.
#
# Deterministic: a fixed RNG seed means the totals are reproducible and safe to quote.
#
# Usage:
#   export LANGFUSE_PUBLIC_KEY=pk-lf-...
#   export LANGFUSE_SECRET_KEY=sk-lf-...
#   export LANGFUSE_HOST=https://jp.cloud.langfuse.com   # jp / us / eu (cloud.langfuse.com)
#   ./scripts/seed-orgs.sh

set -euo pipefail

: "${LANGFUSE_PUBLIC_KEY:?set LANGFUSE_PUBLIC_KEY}"
: "${LANGFUSE_SECRET_KEY:?set LANGFUSE_SECRET_KEY}"
HOST="${LANGFUSE_HOST:-https://jp.cloud.langfuse.com}"

build_batch() {
  python3 - <<'PY'
import json, uuid, random, datetime, sys

# Fixed seed: the aggregate totals must be identical on every run so they can be quoted.
random.seed(42)

now = datetime.datetime.now(datetime.timezone.utc)

# Four tenants on three plans. Deliberately lopsided: one enterprise account on the
# expensive model dominates spend, which is the whole point of per-tenant attribution.
ORGS = [
    # (organizationId, plan, weight, models)
    ("acme-corp", "enterprise", 14, ["claude-opus-5", "claude-opus-5", "claude-sonnet-5"]),
    ("globex",    "pro",         9, ["claude-sonnet-5", "claude-haiku-4-5"]),
    ("initech",   "pro",         8, ["claude-sonnet-5", "claude-sonnet-5", "claude-haiku-4-5"]),
    ("hooli",     "free",        7, ["claude-haiku-4-5"]),
]

# Per-1K-token pricing, only used to make costs internally consistent.
PRICE = {
    "claude-opus-5":    (0.0150, 0.0750),
    "claude-sonnet-5":  (0.0030, 0.0150),
    "claude-haiku-4-5": (0.0008, 0.0040),
}

FEATURES = ["summarize-doc", "chat-turn", "classify", "extract-fields"]

batch = []
for org, plan, weight, models in ORGS:
    for n in range(weight):
        model = random.choice(models)
        feature = random.choice(FEATURES)
        user = f"{org}-user-{random.randint(1, 3)}"

        itok = random.randint(200, 6000)
        otok = random.randint(60, 1500)
        pin, pout = PRICE[model]
        icost = round(itok / 1000 * pin, 6)
        ocost = round(otok / 1000 * pout, 6)

        latency = round(random.uniform(0.5, 8.0), 2)
        start = now - datetime.timedelta(
            days=random.randint(0, 9), minutes=random.randint(0, 1439)
        )
        end = start + datetime.timedelta(seconds=latency)

        trace_id = str(uuid.uuid4())

        batch.append({
            "type": "trace-create",
            "id": str(uuid.uuid4()),
            "timestamp": now.isoformat(),
            "body": {
                "id": trace_id,
                "name": feature,
                "userId": user,
                "sessionId": f"{org}-session-{n // 3}",
                "timestamp": start.isoformat(),
                "tags": ["seed", plan],
                "environment": "default",
                # This is the part that matters: business dimensions on the *trace*.
                "metadata": {
                    "organizationId": org,
                    "plan": plan,
                    "feature": feature,
                    "seeded": True,
                },
            },
        })
        batch.append({
            "type": "generation-create",
            "id": str(uuid.uuid4()),
            "timestamp": now.isoformat(),
            "body": {
                "id": str(uuid.uuid4()),
                "traceId": trace_id,
                "name": feature,
                "startTime": start.isoformat(),
                "endTime": end.isoformat(),
                "completionStartTime": (
                    start + datetime.timedelta(seconds=latency / 3)
                ).isoformat(),
                "model": model,
                "modelParameters": {"temperature": 0.7, "max_tokens": 1024},
                "input": f"[seed] {feature} for {user}",
                "output": f"[seed] completion for {feature}",
                "metadata": {"organizationId": org, "plan": plan, "seeded": True},
                "usageDetails": {"input": itok, "output": otok, "total": itok + otok},
                "costDetails": {
                    "input": icost,
                    "output": ocost,
                    "total": round(icost + ocost, 6),
                },
                "level": "DEFAULT",
                "environment": "default",
            },
        })

traces = sum(1 for e in batch if e["type"] == "trace-create")
print(f"# building {traces} traces across {len(ORGS)} orgs", file=sys.stderr)
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
echo "Done. Ingestion is asynchronous; traces take a few seconds to become queryable."
