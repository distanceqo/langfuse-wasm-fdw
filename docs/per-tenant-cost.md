# Per-tenant LLM cost attribution with Postgres

Your LLM observability tool can tell you what you spent per model, per user, and per session.
The question you actually get asked is different:

> Which customer is this costing us, and are they paying us more than they cost?

That question needs two things at once: your trace data, and your billing data. They live in
different systems, so the answer usually arrives as a CSV export and an afternoon in a
spreadsheet.

This is a walkthrough of doing it in SQL instead, using
[langfuse-wasm-fdw](https://github.com/distanceqo/langfuse-wasm-fdw) — a Postgres foreign data
wrapper that exposes Langfuse traces as a foreign table. Numbers in this post come from a live
Langfuse Cloud project and are reproducible; the seed script is in the repo.

## Why the dashboard can't answer it

Langfuse lets you attach arbitrary `metadata` to a trace. That is the right design — every
product has different dimensions, and no vendor can enumerate them in advance.

It is tempting to read the rest as a UI gap: the dashboard just needs another dropdown. It
isn't. **There is no metadata dimension at any layer of the platform.** Checked against Langfuse
Cloud on 2026-08-16:

| Layer | Aggregates server-side? | Can group by `metadata`? |
| --- | --- | --- |
| Dashboard widgets | yes | no |
| `GET /api/public/metrics` (v1, deprecated) | yes | **no** — dimensions are a fixed list of 9 |
| `GET /api/public/v2/metrics` | yes | **no** — a fixed list of 29, and no `traces` view at all |
| `GET /api/public/traces` | no | n/a — returns whole trace objects |

Asking either metrics endpoint for a metadata dimension is rejected outright:

```
Invalid dimension metadata. Must be one of
id, name, tags, userId, sessionId, release, version, environment, timestampMonth
```

So this is a design constraint, not a missing widget — which changes what a workaround means.
Users have been asking for a while:

- [langfuse#12614 — *Allow using `metadata` fields (e.g. `organizationId`) as Breakdown Dimension*](https://github.com/langfuse/langfuse/issues/12614)
- [langfuse#6091 — *feat: filtering sessions with metadata*](https://github.com/langfuse/langfuse/issues/6091)

Both open. The underlying mismatch: free-form metadata is a *query* problem, and the natural
language for query problems is SQL. Which is available, if the traces are in a database.

## Setup

Once the wrapper is installed, traces are a table:

```sql
create schema if not exists langfuse;
import foreign schema langfuse from server langfuse_server into langfuse;
```

`metadata` arrives as `jsonb`, which is the only part that matters for what follows.

For this walkthrough I seeded 38 traces across four tenants on three plans — one enterprise
account on an expensive model, two mid-tier accounts, one free account on a cheap model. The
seed script (`scripts/seed-orgs.sh`) uses a fixed RNG seed, so the totals below are stable
across runs.

The important detail: the dimensions go on the **trace**, not the generation.

```python
"body": {
    "id": trace_id,
    "name": feature,
    "userId": user,
    "metadata": {
        "organizationId": org,
        "plan": plan,
        "feature": feature,
    },
}
```

This trips people up. If you put `organizationId` only on the generation, a query against the
`traces` table sees `null`, and you will spend a while wondering why.

## The query

```sql
select metadata->>'organizationId' as org,
       metadata->>'plan'           as plan,
       count(*)                    as traces,
       sum(total_cost)::numeric(12,6) as cost_usd
from langfuse.traces
where timestamp >= '2026-08-01'::timestamp
  and timestamp <  '2026-09-01'::timestamp
group by 1, 2
order by cost_usd desc;
```

```
 org        | plan       | traces | cost_usd
------------+------------+--------+----------
 acme-corp  | enterprise |     14 | 1.056645
 (null)     | (null)     |     12 | 0.155705
 initech    | pro        |      8 | 0.147540
 globex     | pro        |      9 | 0.131896
 hooli      | free       |      7 | 0.036900
```

One tenant, 28% of the traces, **77% of the spend**. That is the number you cannot get from a
dashboard that doesn't know your tenants exist.

The `null` row is worth keeping rather than filtering out: those are twelve older traces from a
previous seed that carry no trace-level metadata. Untagged traffic is unattributable traffic,
and it is better to see it as a line item than to have it silently disappear from the
denominator.

### Cross-checking the numbers

Foreign data wrappers are easy to trust incorrectly, so it is worth verifying that the numbers
Postgres reports match the source. Querying the Langfuse Public API directly over the same
window and aggregating in Python gives:

```
acme-corp    enterprise      14    1.056645
None         None            12    0.155705
initech      pro              8    0.147540
globex       pro              9    0.131896
hooli        free             7    0.036900
TOTAL                        50    1.528686
```

Identical to six decimal places, through two independent paths. Worth doing once when you set
this up.

One nit: declare cost columns as `numeric`, not `double precision`. With `double precision` you
will see values like `0.000779999999` in output, which is correct but reads as a bug to whoever
you show it to.

## The part that makes this worth the trouble

Everything above is still just a different view of data Langfuse already has. The reason to put
traces in Postgres is the join:

```sql
select o.name,
       o.plan,
       o.mrr_usd,
       sum(t.total_cost)::numeric(12,6) as llm_cost_usd,
       round((o.mrr_usd - sum(t.total_cost))::numeric, 2) as gross_margin_usd
from public.organizations o
left join langfuse.traces t
       on t.metadata->>'organizationId' = o.slug
      and t.timestamp >= '2026-08-01'::timestamp
      and t.timestamp <  '2026-09-01'::timestamp
group by o.name, o.plan, o.mrr_usd
order by gross_margin_usd asc;
```

Sorted ascending, the top of that result is your list of customers who cost more than they pay.
No observability vendor can compute it, because your revenue is not in their database and never
will be.

## Limits, and how to stay inside them

**Time bounds and equality filters push down; aggregates do not.** The wrapper translates
`timestamp >= ... and timestamp < ...` into `fromTimestamp` / `toTimestamp` query parameters, so
a windowed query fetches only that window. Equality filters on `user_id`, `session_id`,
`trace_id`, `type`, `level` and `name` push down too, and so does `LIMIT`.

`GROUP BY` and `sum()` do not. The plan says so directly:

```
HashAggregate  (cost=1.01..1.02 rows=1 width=40)
  Output: ((metadata ->> 'organizationId'::text)), sum(total_cost)
  Group Key: (traces.metadata ->> 'organizationId'::text)
  ->  Foreign Scan on langfuse.traces  (cost=0.00..1.00 rows=1 width=40)
        Output: (metadata ->> 'organizationId'::text), total_cost
        Filter: ((traces."timestamp" >= '2026-08-01 00:00:00'::timestamp)
             AND (traces."timestamp" <  '2026-09-01 00:00:00'::timestamp))
        Wrappers: quals = [Qual { field: "timestamp", operator: ">=", ... },
                           Qual { field: "timestamp", operator: "<",  ... }]
        Wrappers: tgts  = [Column { name: "metadata",   num: 11, type_oid: 3802 },
                           Column { name: "total_cost", num:  6, type_oid: 701  },
                           Column { name: "timestamp",  num:  8, type_oid: 1114 }]
```

Three things to read out of that.

`HashAggregate` sits **above** `Foreign Scan`, which is the whole story: Postgres asks the
wrapper for rows and does the grouping itself.

`Wrappers: quals` contains both timestamp bounds, so the time window really did reach the API
rather than being filtered after the fact. This is the line to check whenever you are unsure
whether a query is cheap.

`Wrappers: tgts` lists only three columns — and this line is easy to misread, so it is worth
being precise. It describes what **Postgres asks the wrapper for**, not what the wrapper asks
the API for. Those are different, and in this wrapper they currently disagree.

The wrapper uses the column list only to decide which cells to emit per row. The HTTP request is
built from a `fields` server option, which for the `traces` endpoint defaults to sending no
`fields` parameter at all — so the API returns full trace objects, `input` and `output` payloads
included, and the wrapper discards whatever Postgres didn't ask for.

So this query does two wasteful things:

1. It pulls prompt and completion text over the wire in order to sum a float.
2. It fetches **one row per trace**, paginated, to produce five numbers.

The first looks like it should be a cheap local fix — take the column list the framework already
provides and derive a narrower request from it. It isn't available: the `traces` endpoint ignores
the `fields` parameter entirely. Sending `fields=core` and sending nothing return the same 23
keys, `input` and `output` included. Field-group selection exists only on the `v2/` endpoints, and
there is no `v2/traces`.

At 38 traces neither cost is visible. At 38,000 both are.

Two practical consequences:

- **Use literal timestamps, never `now()`.** Postgres only hands the wrapper quals it can
  evaluate up front, so `where timestamp >= now() - interval '7 days'` arrives as an empty qual
  list and degrades to fetching every page before filtering locally. Compute the window in your
  application and inline it. Check with `explain (verbose)` and read the `Wrappers: quals` line:
  a literal shows up there, `now()` doesn't.
- **Materialize for anything recurring.** If a dashboard runs the same aggregate every five
  minutes, land the rows first and aggregate from there:

  ```sql
  create table cost_daily as
  select date_trunc('day', timestamp) as day,
         metadata->>'organizationId'  as org,
         sum(total_cost)              as cost_usd
  from langfuse.traces
  where timestamp >= '2026-08-01'::timestamp
    and timestamp <  '2026-09-01'::timestamp
  group by 1, 2;
  ```

  One pass over the API, then query the table as often as you like.

## What would fix it properly

Aggregate pushdown landed in the Wrappers framework earlier this year
([supabase/wrappers#586](https://github.com/supabase/wrappers/pull/586), merged; the native
MySQL wrapper was wired up to it in [#596](https://github.com/supabase/wrappers/pull/596)).
The Postgres side now collects the aggregates and grouping keys via `GetForeignUpperPaths` and
can hand them to a wrapper.

That plumbing does not currently reach Wasm wrappers. The guest-facing interface exposes only
three things:

```wit
resource qual   // get-quals
resource sort   // get-sorts
resource limit  // get-limit
```

There is no channel for "the caller only wants `sum(total_cost)`, grouped by this expression".
A Wasm wrapper is told which *columns* are needed, but never that the caller is running an
aggregate — so it cannot make the one decision that would matter, which is to ask the remote
for a total instead of for rows.

Wiring that through would pay off, because Langfuse does aggregate server-side. This works:

```
GET /api/public/metrics?query={"view":"traces",
  "dimensions":[{"field":"name"}],
  "metrics":[{"measure":"totalCost","aggregation":"sum"}], ...}

{"data":[{"name":"summarize-doc","sum_totalCost":0.490354}, ...]}
```

One request, aggregated remotely, instead of paginating every row. A wrapper that knew it was
serving `select name, sum(total_cost) ... group by name` could route to that endpoint.

And here is the part I did not expect. **The aggregate you most want to push down is the one
that can never be pushed down.** `group by user_id` maps onto a supported dimension and would
become a single cheap request. `group by metadata->>'organizationId'` cannot, at any volume,
ever — because the remote has no metadata dimension to group by, as the table at the top of
this post shows.

So for the query this whole post is about, fetching rows and aggregating in Postgres is not a
fallback until something better arrives. It is the only architecture that answers the question
at all, and materializing is how you make it scale. That is a more interesting reason to put
traces in a database than "SQL is nicer than a dropdown."

Aggregate pushdown for Wasm wrappers is still worth building — for `user_id`, `name`, `tags`,
`environment` and the rest of the supported list it turns N requests into one. It just isn't
what fixes per-tenant cost.

---

*Wrapper: [distanceqo/langfuse-wasm-fdw](https://github.com/distanceqo/langfuse-wasm-fdw),
also shipping in the official catalog as
[supabase/wrappers#622](https://github.com/supabase/wrappers/pull/622). Tested against Langfuse
Cloud (JP) on Supabase with `wrappers` 0.6.2.*
