-- Install the Langfuse Wasm FDW on a Supabase project.
-- Paste into the dashboard SQL Editor and run as a whole.
--
-- Replace the placeholders marked <...> first. The package URL, version, and checksum
-- come from the GitHub release; the keys come from Langfuse project settings.

create extension if not exists wrappers with schema extensions;

-- CREATE FOREIGN DATA WRAPPER has no IF NOT EXISTS form, so guard it by hand —
-- re-running the script should not fail on an already-installed wrapper.
do $$
begin
  if not exists (select 1 from pg_foreign_data_wrapper where fdwname = 'wasm_wrapper') then
    create foreign data wrapper wasm_wrapper
      handler wasm_fdw_handler
      validator wasm_fdw_validator;
  end if;
end $$;


-- ── 1. Keys into Vault ───────────────────────────────────────────────
-- Storing them here keeps the keys out of `create server` DDL, out of pg_dump, and
-- out of anything that reads pg_foreign_server.
-- Note the returned UUIDs; they go into the server options below.
-- Do not commit real keys here; this file is tracked. Paste them straight into the
-- SQL Editor instead.
select vault.create_secret('<pk-lf-...>', 'langfuse_public_key');
select vault.create_secret('<sk-lf-...>', 'langfuse_secret_key');


-- Look them up again later with:
--   select id, name from vault.secrets where name like 'langfuse%';


-- ── 2. Server ────────────────────────────────────────────────────────
create server langfuse_server
  foreign data wrapper wasm_wrapper
  options (
    fdw_package_url 'https://github.com/distanceqo/langfuse-wasm-fdw/releases/download/v0.1.0/langfuse_fdw.wasm',
    fdw_package_name 'distanceqo:langfuse-fdw',
    fdw_package_version '0.1.0',
    fdw_package_checksum '4f8f798ff26c0b0bc2955c67d84ae5d0c2525c181f6f18c75bac5fb4fa8fe418',
    -- jp / us / eu — must match the region the project was created in, keys are
    -- region-bound and will 401 elsewhere
    api_url 'https://jp.cloud.langfuse.com',
    public_key_id '<public key secret UUID>',
    secret_key_id '<secret key secret UUID>'
  );


-- ── 3. Foreign tables ────────────────────────────────────────────────
create schema if not exists langfuse;

-- Traces carry user_id and aggregate cost, so this is the table to join against.
create foreign table langfuse.traces (
  id text,
  name text,
  user_id text,
  session_id text,
  environment text,
  release text,
  version text,
  total_cost double precision,
  latency double precision,
  timestamp timestamp,
  created_at timestamp,
  updated_at timestamp,
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

-- Observations are per-model-call, with token counts and per-call cost. They carry no
-- user_id in the response (it lives on the trace), though it can still be used as a
-- filter — see the note in the README.
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
  time_to_first_token double precision,
  start_time timestamp,
  end_time timestamp,
  completion_start_time timestamp,
  prompt_name text,
  prompt_version bigint,
  input text,
  output text,
  metadata jsonb,
  model_parameters jsonb
)
  server langfuse_server
  options (
    object 'observations',
    rowid_column 'id'
  );


-- ── 4. Smoke tests ───────────────────────────────────────────────────

-- Cheapest possible check: one row, one upstream request.
select id, name, user_id, total_cost from langfuse.traces limit 1;

-- Cost per user. This is the query the wrapper exists for — swap in a join against
-- your own users table.
select user_id,
       count(*)          as traces,
       sum(total_cost)   as cost_usd,
       round(avg(latency)::numeric, 2) as avg_latency_s
from langfuse.traces
group by user_id
order by cost_usd desc;

-- Token usage by model, from the observation level.
select model,
       count(*)            as calls,
       sum(input_tokens)   as input_tokens,
       sum(output_tokens)  as output_tokens,
       sum(total_cost)     as cost_usd
from langfuse.observations
group by model
order by cost_usd desc;

-- Verifies equality pushdown: this should hit the API with ?userId=user-alice
-- rather than fetching every page and filtering locally.
select count(*) from langfuse.traces where user_id = 'user-alice';
