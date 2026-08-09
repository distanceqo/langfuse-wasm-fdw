#!/bin/bash
# Seed a Langfuse project via the OpenTelemetry endpoint.
#
# The legacy /api/public/ingestion endpoint writes rows that the v1 read APIs can see
# but the v2 APIs cannot — v2 reads the events table populated by OTLP ingestion. Since
# the wrapper targets v2, seed through OTLP.
#
# Usage:
#   export LANGFUSE_PUBLIC_KEY=pk-lf-... LANGFUSE_SECRET_KEY=sk-lf-...
#   export LANGFUSE_HOST=https://jp.cloud.langfuse.com
#   ./scripts/seed-otel.sh

set -euo pipefail

: "${LANGFUSE_PUBLIC_KEY:?set LANGFUSE_PUBLIC_KEY}"
: "${LANGFUSE_SECRET_KEY:?set LANGFUSE_SECRET_KEY}"
HOST="${LANGFUSE_HOST:-https://jp.cloud.langfuse.com}"

build_payload() {
  python3 - <<'PY'
import json, os, secrets, sys, time

now_ns = time.time_ns()

# (user, model, in_tok, out_tok, in_cost, out_cost, latency_s, minutes_ago, name)
rows = [
    ("user-alice", "claude-opus-5",     1200,  340, 0.0180, 0.0255, 4.2,   5, "summarize-doc"),
    ("user-alice", "claude-opus-5",      890,  210, 0.0134, 0.0158, 2.8,  40, "summarize-doc"),
    ("user-bob",   "claude-sonnet-5",   4300, 1100, 0.0129, 0.0165, 6.1,  70, "chat-turn"),
    ("user-bob",   "claude-sonnet-5",    620,  180, 0.0019, 0.0027, 1.4, 130, "chat-turn"),
    ("user-bob",   "claude-haiku-4-5",   310,   95, 0.0002, 0.0004, 0.7, 190, "classify"),
    ("user-carol", "claude-haiku-4-5",   180,   60, 0.0001, 0.0002, 0.5, 260, "classify"),
]

def attr(k, v):
    if isinstance(v, bool):
        return {"key": k, "value": {"boolValue": v}}
    if isinstance(v, int):
        return {"key": k, "value": {"intValue": str(v)}}
    if isinstance(v, float):
        return {"key": k, "value": {"doubleValue": v}}
    return {"key": k, "value": {"stringValue": str(v)}}

spans = []
for i, (user, model, itok, otok, icost, ocost, latency, mins, name) in enumerate(rows):
    start_ns = now_ns - mins * 60 * 1_000_000_000
    end_ns = start_ns + int(latency * 1_000_000_000)

    spans.append({
        "traceId": secrets.token_hex(16),
        "spanId": secrets.token_hex(8),
        "name": name,
        # SPAN_KIND_CLIENT
        "kind": 3,
        "startTimeUnixNano": str(start_ns),
        "endTimeUnixNano": str(end_ns),
        "attributes": [
            # GenAI semantic conventions — Langfuse maps these onto its data model
            attr("gen_ai.operation.name", "chat"),
            attr("gen_ai.request.model", model),
            attr("gen_ai.response.model", model),
            attr("gen_ai.usage.input_tokens", itok),
            attr("gen_ai.usage.output_tokens", otok),
            attr("gen_ai.request.temperature", 0.7),
            attr("gen_ai.request.max_tokens", 1024),
            # Langfuse-specific attributes for fields OTel has no convention for
            attr("langfuse.user.id", user),
            attr("langfuse.session.id", f"session-{i // 2}"),
            attr("langfuse.observation.type", "generation"),
            attr("langfuse.observation.input", json.dumps(
                {"messages": [{"role": "user", "content": f"[seed] prompt for {name} from {user}"}]}
            )),
            attr("langfuse.observation.output", json.dumps(
                {"content": f"[seed] completion for {name}"}
            )),
            attr("langfuse.observation.metadata.seeded", "true"),
            attr("langfuse.observation.metadata.plan_hint", user.split("-")[1]),
            attr("langfuse.observation.cost_details.input", icost),
            attr("langfuse.observation.cost_details.output", ocost),
            attr("langfuse.trace.tags", "seed"),
        ],
        "status": {"code": 1},
    })

payload = {
    "resourceSpans": [{
        "resource": {
            "attributes": [
                attr("service.name", "langfuse-fdw-seed"),
                attr("deployment.environment.name", "default"),
            ]
        },
        "scopeSpans": [{
            "scope": {"name": "langfuse-fdw-seed", "version": "0.1.0"},
            "spans": spans,
        }],
    }]
}

json.dump(payload, sys.stdout)
PY
}

AUTH=$(printf '%s:%s' "$LANGFUSE_PUBLIC_KEY" "$LANGFUSE_SECRET_KEY" | base64)

echo "Seeding ${HOST} via OTLP ..."
resp=$(build_payload | curl -sS -w '\n%{http_code}' --max-time 60 \
  -H "authorization: Basic ${AUTH}" \
  -H 'content-type: application/json' \
  -X POST "${HOST}/api/public/otel/v1/traces" \
  --data-binary @-)

code=$(printf '%s' "$resp" | tail -1)
body=$(printf '%s' "$resp" | sed '$d')

echo "HTTP ${code}"
printf '%s\n' "$body" | /usr/bin/head -c 800
echo
echo "Done. Spans take a few seconds to become queryable."
