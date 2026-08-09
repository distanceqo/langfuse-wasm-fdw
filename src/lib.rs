#[allow(warnings)]
mod bindings;
use serde_json::Value as JsonValue;

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use bindings::{
    exports::supabase::wrappers::routines::Guest,
    supabase::wrappers::{
        http, time,
        types::{Cell, Context, FdwError, FdwResult, OptionsType, Row, TypeOid, Value},
        utils,
    },
};

// Langfuse returns a page of rows plus an opaque cursor. We fetch lazily: one page is
// buffered at a time and the next page is pulled once the buffer is drained, so a
// `limit 10` on a million-row project costs a single request.
#[derive(Debug, Default)]
struct LangfuseFdw {
    base_url: String,
    auth_header: String,
    // resolved per-scan from the foreign table's `object` option
    endpoint: String,
    // query string carrying pushed-down filters, rebuilt per page with a new cursor
    filter_qs: String,
    // `fields` field-group selection for the v2 endpoints; empty for the others
    fields: String,
    src_rows: Vec<JsonValue>,
    src_idx: usize,
    next_cursor: Option<String>,
    // page number for the offset-paginated endpoints; 0 means "first request"
    next_page: i64,
    // None once the API stops handing back a cursor
    has_more: bool,
    // rows still to return; None means unlimited
    remaining: Option<i64>,
    page_size: i64,
}

static mut INSTANCE: *mut LangfuseFdw = std::ptr::null_mut::<LangfuseFdw>();

impl LangfuseFdw {
    fn init_instance() {
        let instance = Self::default();
        unsafe {
            INSTANCE = Box::leak(Box::new(instance));
        }
    }

    fn this_mut() -> &'static mut Self {
        unsafe { &mut (*INSTANCE) }
    }

    // Only equality on the handful of columns Langfuse accepts as query params is
    // pushed down; everything else is left for Postgres to filter locally.
    fn pushdown_quals(ctx: &Context) -> String {
        const PUSHABLE: [&str; 6] = [
            "trace_id",
            "user_id",
            "session_id",
            "type",
            "level",
            "name",
        ];

        let mut qs = String::new();
        for qual in ctx.get_quals().iter() {
            if qual.operator() != "=" || qual.use_or() {
                continue;
            }
            let field = qual.field();
            if !PUSHABLE.contains(&field.as_str()) {
                continue;
            }
            // parameterised quals resolve too late to help us here
            let Value::Cell(Cell::String(v)) = qual.value() else {
                continue;
            };
            qs.push_str(&format!("&{}={}", to_camel_case(&field), url_encode(&v)));
        }
        qs
    }

    fn fetch_page(&mut self) -> Result<(), FdwError> {
        // ask for no more rows than the query still needs
        let limit = match self.remaining {
            Some(n) if n < self.page_size => n,
            _ => self.page_size,
        };

        let mut url = format!(
            "{}/api/public/{}?limit={}{}{}",
            self.base_url, self.endpoint, limit, self.fields, self.filter_qs
        );
        if let Some(cursor) = &self.next_cursor {
            url.push_str(&format!("&cursor={}", url_encode(cursor)));
        } else if self.next_page > 1 {
            url.push_str(&format!("&page={}", self.next_page));
        }

        let headers: Vec<(String, String)> = vec![
            ("authorization".to_owned(), self.auth_header.clone()),
            ("user-agent".to_owned(), "langfuse-wasm-fdw".to_owned()),
            ("accept".to_owned(), "application/json".to_owned()),
        ];

        let req = http::Request {
            method: http::Method::Get,
            url,
            headers,
            body: String::default(),
        };
        let resp = http::get(&req)?;
        // surfaces 401/403 as a Postgres error rather than an empty result set
        http::error_for_status(&resp)
            .map_err(|err| format!("{}: {}", err, resp.body))?;

        let resp_json: JsonValue = serde_json::from_str(&resp.body).map_err(|e| e.to_string())?;

        self.src_rows = resp_json
            .get("data")
            .and_then(|v| v.as_array())
            .map(|v| v.to_owned())
            .ok_or("response has no 'data' array")?;
        self.src_idx = 0;

        // Two pagination styles are in play: the v2/v3 endpoints hand back an opaque
        // cursor, the older ones report page/totalPages. Follow whichever the response
        // carries so one wrapper serves both.
        let meta = resp_json.get("meta");
        self.next_cursor = meta
            .and_then(|m| m.get("cursor"))
            .and_then(|c| c.as_str())
            .map(|s| s.to_owned());

        if self.next_cursor.is_some() {
            self.has_more = !self.src_rows.is_empty();
        } else {
            let page = meta.and_then(|m| m.get("page")).and_then(|p| p.as_i64());
            let total_pages = meta
                .and_then(|m| m.get("totalPages"))
                .and_then(|p| p.as_i64());
            match (page, total_pages) {
                (Some(p), Some(total)) => {
                    self.next_page = p + 1;
                    self.has_more = p < total && !self.src_rows.is_empty();
                }
                // no pagination metadata at all: treat as a single page
                _ => self.has_more = false,
            }
        }

        Ok(())
    }
}

// Postgres columns are snake_case by convention, the Langfuse API is camelCase.
fn to_camel_case(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut upper_next = false;
    for c in s.chars() {
        if c == '_' {
            upper_next = true;
        } else if upper_next {
            out.push(c.to_ascii_uppercase());
            upper_next = false;
        } else {
            out.push(c);
        }
    }
    out
}

fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

// `usage_details` and `cost_details` arrive as objects keyed by metric name, with a
// `total` key summing the rest. Flattening the common totals into scalar columns keeps
// the useful aggregations (sum(total_cost)) out of jsonb extraction.
fn lookup_source<'a>(src_row: &'a JsonValue, col: &str) -> Option<&'a JsonValue> {
    let obj = src_row.as_object()?;

    let direct = obj.get(&to_camel_case(col));
    if direct.is_some_and(|v| !v.is_null()) {
        return direct;
    }

    // Fall back to the flat aliases the older endpoints use: costs are exposed as
    // `calculated*Cost` there, token counts as `promptTokens`/`completionTokens`.
    let fallback = |names: &[&str]| -> Option<&'a JsonValue> {
        names
            .iter()
            .filter_map(|n| obj.get(*n))
            .find(|v| !v.is_null())
    };

    let (group, key) = match col {
        "total_cost" => ("costDetails", "total"),
        "input_cost" => ("costDetails", "input"),
        "output_cost" => ("costDetails", "output"),
        "total_tokens" => ("usageDetails", "total"),
        "input_tokens" => ("usageDetails", "input"),
        "output_tokens" => ("usageDetails", "output"),
        // v2 renamed `model` to `providedModelName`; accept either spelling so the
        // same foreign table definition works against both.
        "provided_model_name" => return obj.get("model"),
        "model" => return obj.get("providedModelName"),
        _ => return direct,
    };

    obj.get(group)
        .and_then(|g| g.as_object())
        .and_then(|g| g.get(key))
        .filter(|v| !v.is_null())
        .or_else(|| match col {
            "total_cost" => fallback(&["calculatedTotalCost", "totalCost", "totalPrice"]),
            "input_cost" => fallback(&["calculatedInputCost", "inputPrice"]),
            "output_cost" => fallback(&["calculatedOutputCost", "outputPrice"]),
            "input_tokens" => fallback(&["promptTokens"]),
            "output_tokens" => fallback(&["completionTokens"]),
            _ => None,
        })
        .or(direct)
}

impl Guest for LangfuseFdw {
    fn host_version_requirement() -> String {
        // semver expression for Wasm FDW host version requirement
        // ref: https://docs.rs/semver/latest/semver/enum.Op.html
        "^0.1.0".to_string()
    }

    fn init(ctx: &Context) -> FdwResult {
        Self::init_instance();
        let this = Self::this_mut();

        let opts = ctx.get_options(OptionsType::Server);
        this.base_url = opts
            .require_or("api_url", "https://cloud.langfuse.com")
            .trim_end_matches('/')
            .to_owned();
        this.page_size = opts
            .require_or("page_size", "100".to_owned().as_str())
            .parse::<i64>()
            .map_err(|e| format!("invalid page_size: {}", e))?;

        // Keys live in Vault so they never appear in `create server` DDL or pg_dump
        // output. Plaintext options stay available for local development.
        let public_key = match opts.get("public_key_id") {
            Some(id) => utils::get_vault_secret(&id).ok_or("public_key_id not found in Vault")?,
            None => opts.require("public_key")?,
        };
        let secret_key = match opts.get("secret_key_id") {
            Some(id) => utils::get_vault_secret(&id).ok_or("secret_key_id not found in Vault")?,
            None => opts.require("secret_key")?,
        };

        this.auth_header = format!(
            "Basic {}",
            BASE64.encode(format!("{}:{}", public_key, secret_key))
        );

        Ok(())
    }

    fn begin_scan(ctx: &Context) -> FdwResult {
        let this = Self::this_mut();

        let opts = ctx.get_options(OptionsType::Table);
        this.endpoint = opts.require("object")?;
        this.filter_qs = Self::pushdown_quals(ctx);

        // The v2 endpoints return only the `core` and `basic` groups unless asked
        // otherwise, which would leave usage/cost columns silently NULL. Request the
        // groups backing the columns this wrapper exposes.
        this.fields = match opts.get("fields") {
            Some(f) => format!("&fields={}", url_encode(&f)),
            None if this.endpoint.starts_with("v2/") => {
                "&fields=core,basic,time,io,metadata,model,usage,metrics,trace_context".to_owned()
            }
            None => String::new(),
        };

        // A pushed-down LIMIT bounds total rows fetched. Postgres re-checks it anyway,
        // so over-fetching would only waste requests.
        this.remaining = ctx
            .get_limit()
            .map(|l| l.offset().saturating_add(l.count()));

        this.next_cursor = None;
        this.has_more = false;
        this.fetch_page()
    }

    fn iter_scan(ctx: &Context, row: &Row) -> Result<Option<u32>, FdwError> {
        let this = Self::this_mut();

        if this.remaining == Some(0) {
            return Ok(None);
        }

        // current page drained: pull the next one, if any
        if this.src_idx >= this.src_rows.len() {
            if !this.has_more {
                return Ok(None);
            }
            this.fetch_page()?;
            if this.src_rows.is_empty() {
                return Ok(None);
            }
        }

        let src_row = &this.src_rows[this.src_idx];
        for tgt_col in ctx.get_columns() {
            let tgt_col_name = tgt_col.name();
            // A column absent from this field group is NULL rather than an error —
            // `fields` selection means the API legitimately omits keys.
            let src = match lookup_source(src_row, &tgt_col_name) {
                Some(v) => v,
                None => {
                    row.push(None);
                    continue;
                }
            };
            let cell = match tgt_col.type_oid() {
                TypeOid::Bool => src.as_bool().map(Cell::Bool),
                TypeOid::String => match src {
                    // input/output/metadata are arbitrary JSON; render them as text
                    // instead of failing when a text column receives an object
                    JsonValue::String(s) => Some(Cell::String(s.to_owned())),
                    JsonValue::Null => None,
                    other => Some(Cell::String(other.to_string())),
                },
                TypeOid::I32 => src.as_i64().map(|v| Cell::I32(v as i32)),
                TypeOid::I64 => src.as_i64().map(Cell::I64),
                TypeOid::F64 => src.as_f64().map(Cell::F64),
                TypeOid::Numeric => src.as_f64().map(Cell::Numeric),
                TypeOid::Timestamp => match src.as_str() {
                    Some(s) => Some(Cell::Timestamp(time::parse_from_rfc3339(s)?)),
                    None => None,
                },
                TypeOid::Timestamptz => match src.as_str() {
                    Some(s) => Some(Cell::Timestamptz(time::parse_from_rfc3339(s)?)),
                    None => None,
                },
                TypeOid::Json => match src {
                    JsonValue::Null => None,
                    other => Some(Cell::Json(other.to_string())),
                },
                _ => {
                    return Err(format!(
                        "column {} data type is not supported",
                        tgt_col_name
                    ));
                }
            };

            row.push(cell.as_ref());
        }

        this.src_idx += 1;
        this.remaining = this.remaining.map(|n| n - 1);

        Ok(Some(0))
    }

    fn re_scan(_ctx: &Context) -> FdwResult {
        Err("re_scan on foreign table is not supported".to_owned())
    }

    fn end_scan(_ctx: &Context) -> FdwResult {
        let this = Self::this_mut();
        this.src_rows.clear();
        this.src_idx = 0;
        this.next_cursor = None;
        this.has_more = false;
        Ok(())
    }

    fn begin_modify(_ctx: &Context) -> FdwResult {
        Err("modify on foreign table is not supported".to_owned())
    }

    fn insert(_ctx: &Context, _row: &Row) -> FdwResult {
        Ok(())
    }

    fn update(_ctx: &Context, _rowid: Cell, _row: &Row) -> FdwResult {
        Ok(())
    }

    fn delete(_ctx: &Context, _rowid: Cell) -> FdwResult {
        Ok(())
    }

    fn end_modify(_ctx: &Context) -> FdwResult {
        Ok(())
    }
}

bindings::export!(LangfuseFdw with_types_in bindings);
