# Langfuse Wasm FDW

A Postgres [Foreign Data Wrapper](https://fdw.dev) for [Langfuse](https://langfuse.com),
built with the [Wrappers](https://github.com/supabase/wrappers) framework and compiled to
WebAssembly.

It exposes Langfuse LLM observability data — traces, observations, token usage, cost — as
Postgres foreign tables, so you can join your own application tables against it in plain
SQL:

```sql
-- Which plan costs the most?
select u.plan,
       count(*)            as traces,
       sum(t.total_cost)   as cost_usd
from public.users u
join langfuse.traces t on t.user_id = u.id::text
where t.timestamp >= now() - interval '30 days'
group by u.plan
order by cost_usd desc;
```

## Why an FDW and not the ClickHouse wrapper

Langfuse stores trace data in ClickHouse, and Supabase ships a ClickHouse wrapper — so
why this one? Because Langfuse states plainly that
[the ClickHouse schema is not a stable API contract](https://langfuse.com/self-hosting/infrastructure/clickhouse):

> Major Langfuse upgrades, background migrations, and performance work ... can change
> tables, columns, deduplication behavior, or join patterns at any time.

The documented compatibility targets are the Public API, the SDKs, the MCP server, and
blob-storage export. This wrapper targets the Public API. It also works for Langfuse Cloud
users, who have no ClickHouse connection string at all.

## Installation

Build artifacts are attached to each [release](../../releases). On Supabase:

```sql
create extension if not exists wrappers with schema extensions;

create foreign data wrapper wasm_wrapper
  handler wasm_fdw_handler
  validator wasm_fdw_validator;
```

Store the API keys in Vault so they never land in DDL or a `pg_dump`:

```sql
select vault.create_secret('pk-lf-...', 'langfuse_public_key');
select vault.create_secret('sk-lf-...', 'langfuse_secret_key');
```

Then create the server, passing the secret UUIDs returned above:

```sql
create server langfuse_server
  foreign data wrapper wasm_wrapper
  options (
    fdw_package_url 'https://github.com/distanceqo/langfuse-wasm-fdw/releases/download/v0.2.0/langfuse_fdw.wasm',
    fdw_package_name 'distanceqo:langfuse-fdw',
    fdw_package_version '0.2.0',
    fdw_package_checksum 'dab63e365a684f4033322b66868b89ed3c21494973ff67836b223643bb9a7803',
    -- must match the region the project was created in; keys are region-bound
    api_url 'https://jp.cloud.langfuse.com',
    public_key_id '<public key secret UUID>',
    secret_key_id '<secret key secret UUID>'
  );
```

### Server options

| Option | Required | Default | Notes |
| --- | --- | --- | --- |
| `api_url` | no | `https://cloud.langfuse.com` | `jp.` / `us.` prefix for those regions, or your self-hosted URL |
| `public_key_id` | one of | — | Vault secret UUID holding the public key |
| `public_key` | one of | — | Plaintext key; for local development only |
| `secret_key_id` | one of | — | Vault secret UUID holding the secret key |
| `secret_key` | one of | — | Plaintext key; for local development only |
| `page_size` | no | `100` | Rows per upstream request, max 1000 |
| `verbose` | no | `false` | Set to `'true'` to log each request URL as an `INFO` message |

## Foreign tables

```sql
create schema langfuse;

-- Traces carry user_id and aggregate cost — the table to join against.
create foreign table langfuse.traces (
  id text,
  name text,
  user_id text,
  session_id text,
  environment text,
  total_cost double precision,
  latency double precision,
  timestamp timestamp,
  input text,
  output text,
  metadata jsonb,
  tags jsonb
)
  server langfuse_server
  options (
    object 'traces',
    rowid_column 'id'
  );

-- Observations are per-model-call, with token counts and per-call cost.
create foreign table langfuse.observations (
  id text,
  trace_id text,
  type text,
  name text,
  level text,
  model text,
  input_tokens bigint,
  output_tokens bigint,
  total_tokens bigint,
  input_cost double precision,
  output_cost double precision,
  total_cost double precision,
  latency double precision,
  start_time timestamp,
  end_time timestamp,
  input text,
  output text,
  metadata jsonb
)
  server langfuse_server
  options (
    object 'observations',
    rowid_column 'id'
  );
```

`scripts/install.sql` has the full version of this, with smoke-test queries.

### Table options

| Option | Required | Notes |
| --- | --- | --- |
| `object` | yes | API path after `/api/public/`, e.g. `v2/observations`, `traces`, `sessions` |
| `fields` | no | Field groups to request. Defaults to everything this wrapper maps, for `v2/` endpoints |

### Column naming

Columns are snake_case and mapped to the API's camelCase automatically —
`provided_model_name` reads `providedModelName`. A column the API does not return is
NULL rather than an error, so you can declare only the columns you need.

Langfuse returns usage and cost as nested objects keyed by metric name. These are
flattened into scalar columns so aggregates work directly:

| Column | Source |
| --- | --- |
| `total_tokens` | `usageDetails.total` |
| `input_tokens` | `usageDetails.input`, else `promptTokens` |
| `output_tokens` | `usageDetails.output`, else `completionTokens` |
| `total_cost` | `costDetails.total`, else `calculatedTotalCost` / `totalCost` |
| `input_cost` | `costDetails.input`, else `calculatedInputCost` |
| `output_cost` | `costDetails.output`, else `calculatedOutputCost` |

The fallbacks matter in practice: the `observations` endpoint returns cost as
`calculatedTotalCost` and has no `totalCost` key at all.

`input`, `output`, and `metadata` hold arbitrary JSON. Declare them as `jsonb` to query
into them, or as `text` to get the raw value.

## Which endpoint to point at

`object` takes any path under `/api/public/`. Two are worth knowing about:

- **`traces`** — carries `user_id`, aggregate `total_cost`, and `latency`. This is the
  table to join your own users against.
- **`observations`** — one row per model call, with token counts and per-call cost. It
  does *not* return `user_id` (that lives on the trace), though `where user_id = ...` is
  still accepted as a filter and pushed down. Join through `trace_id` to attribute calls
  to users.

There is also a `v2/observations` endpoint, which is what upstream currently recommends.
Be aware that **v2 reads a different store than v1**: on a freshly created cloud project,
rows ingested through both `/api/public/ingestion` and the OTLP endpoint were visible to
`observations` but `v2/observations` returned `{"data":[],"meta":{}}` — while still
validating parameters, so the endpoint is live, just empty. Until that settles, point
`object` at `observations`. The wrapper handles both: it follows a cursor when the
response carries one and falls back to page numbers otherwise, and accepts either
spelling of the renamed fields (`model` / `providedModelName`).

## Pushdown

Equality filters on `trace_id`, `user_id`, `session_id`, `type`, `level`, and `name` are
pushed to the API as query parameters. `LIMIT` is pushed down too, so `limit 10` costs one
request regardless of project size. Pages are fetched lazily as the scan consumes them.

Time bounds are pushed down as well, which is what makes time-windowed queries cheap:

```sql
-- reaches the API as ?fromTimestamp=2026-08-02T00:00:00Z&toTimestamp=2026-08-09T00:00:00Z
select * from langfuse.traces
where timestamp >= '2026-08-02'::timestamp
  and timestamp <  '2026-08-09'::timestamp;
```

**Use literal timestamps, not `now()`.** Postgres only hands the wrapper quals it can
evaluate up front, so `where timestamp >= now() - interval '7 days'` arrives as an empty
qual list and is filtered locally after every page has been fetched. Confirm with
`explain (verbose)` and read the `Wrappers: quals` line:

```
-- with now():      Wrappers: quals = []
-- with a literal:  Wrappers: quals = [Qual { field: "timestamp", operator: ">=", ... }]
```

Compute the window in your application, or inline it as a literal. (`Filter:` still lists
the condition either way — Postgres always re-checks pushed-down quals.)

The column and the parameters differ per endpoint, and the wrapper picks the right pair:
`observations` filters `start_time` via `fromStartTime`/`toStartTime`, everything else
filters `timestamp` via `fromTimestamp`/`toTimestamp`.

Only `>=` and `<` are pushed, matching the API's inclusive-from / exclusive-to semantics.
`>` and `<=` would need an epsilon shift to stay correct, so those are left to Postgres —
the query still works, it just fetches more pages. Everything else is filtered locally
too; Postgres re-checks every pushed-down qual regardless, so a coarse pushdown is safe.

To see what actually reached the API, set `verbose 'true'` on the server:

```
langfuse_fdw: GET https://jp.cloud.langfuse.com/api/public/traces?limit=100&fromTimestamp=...
```

Note that the Supabase dashboard SQL Editor does not surface `INFO` messages, so these
lines only appear over a real Postgres connection (`psql`, or any client that forwards
server notices). From the dashboard, use `explain (verbose)` and read `Wrappers: quals`
instead.

## Seeding test data

Two scripts populate a project so there is something to query. Both need
`LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, and `LANGFUSE_HOST` in the environment.

```bash
./scripts/seed.sh       # via /api/public/ingestion
./scripts/seed-otel.sh  # via /api/public/otel/v1/traces (OTLP/JSON)
```

They write six generations across three users on different models, with uneven costs so
`group by` output is easy to eyeball. Ingestion is asynchronous — rows take a few seconds
to become queryable.

## Development

Regional hosts, since keys are bound to the region the project was created in:
`jp.cloud.langfuse.com`, `us.cloud.langfuse.com`, `cloud.langfuse.com` (EU). Using a key
against the wrong one returns 401.

```bash
rustup target add wasm32-unknown-unknown
cargo install cargo-component --locked --version 0.13.2
rustup component add rustfmt

cargo component build --release --target wasm32-unknown-unknown
```

The build emits `target/wasm32-unknown-unknown/release/langfuse_fdw.wasm`. `local-dev.sh`
copies it into a running `supabase start` database container for testing against a local
Postgres.

Pushing a `v*.*.*` tag triggers the release workflow, which builds the component,
computes its checksum, and publishes both to a GitHub release along with ready-to-paste
SQL.

## Status and limitations

Working: cursor *and* page-number pagination, Vault-backed auth, LIMIT and equality
pushdown, usage/cost flattening with fallbacks, field-group selection.

End-to-end verified on Supabase against a live Langfuse Cloud (JP) project: the component
loads, authenticates out of Vault, and returns rows that aggregate correctly.

`sum(total_cost)` over `traces` and over `observations` agree at `0.15584` for the same
seeded data, despite reaching the value through different response fields
(`totalCost` vs `calculatedTotalCost`) — which is what makes the fallback chains worth
having. `where user_id = ...` pushed down and returned a count matching the per-user
aggregate.

Note that `double precision` columns show float artifacts (`0.000779999999`). Declare cost
columns as `numeric` if you need exact decimal output.

Not done yet:

- **`now()` in a time filter.** Not pushed down — Postgres does not put it in the qual
  list. Inline a literal timestamp instead; see Pushdown above.
- **`>` and `<=` time bounds.** Not pushed down, since the API's bounds are
  inclusive-from / exclusive-to and shifting by an epsilon risks dropping rows. Use `>=`
  and `<` to get the cheap path.
- **`user_id` on observations.** Accepted as a filter, absent from the response. Join
  through `trace_id` to attribute a call to a user.
- **Other endpoints.** `sessions` and `v3/scores` should work via `object` but are
  unverified. `v3/scores` responded with an empty `data` array and no page metadata,
  which the wrapper treats as a single page.
- **`re_scan`.** Returns an error, so this wrapper cannot sit on the inner side of a
  nested-loop join. Materialize with a CTE if you hit this.

## License

[Apache License Version 2.0](./LICENSE)
