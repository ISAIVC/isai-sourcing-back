import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
    status,
  });
}

// ---------------------------------------------------------------------------
// TypeScript types (copied from parse-free-text-query/index.ts)
// ---------------------------------------------------------------------------

type TagCol =
  | "fund_prime_scope"
  | "hq_country"
  | "hq_city"
  | "gtm_target_cg"
  | "gtm_target_by"
  | "vc_current_stage"
  | "business_model"
  | "primary_sector_served_cg"
  | "primary_industry_served_cg"
  | "primary_sector_served_by"
  | "primary_industry_served_by"
  | "business_mapping"
  | "last_stage_in_attio"
  | "last_status_in_attio";

type MultitagCol =
  | "global_2000_clients"
  | "cg_key_platforms"
  | "by_key_platforms"
  | "competitors_cg"
  | "competitors_by"
  | "affiliates_cg"
  | "affiliates_by"
  | "all_investors"
  | "last_round_lead_investors"
  | "all_industries_served"
  | "tech_tags";

type NumberCol =
  | "inc_date"
  | "number_of_clients_identified"
  | "first_vc_round_amount"
  | "total_amount_raised"
  | "last_funding_amount"
  | "total_nber_of_rounds"
  | "solution_fit_cg"
  | "solution_fit_by"
  | "business_fit_cg"
  | "business_fit_by"
  | "maturity_fit"
  | "equity_score"
  | "traction_score"
  | "global_fund_score";

interface TagFilter {
  col: TagCol;
  op: "in" | "not_null";
  val?: string[];
}

interface MultitagFilter {
  col: MultitagCol;
  op: "contains" | "not_empty";
  val?: string[];
}

interface TextFilter {
  col: "name" | "domain";
  op: "contains" | "not_null";
  val?: string;
}

interface NumberFilter {
  col: NumberCol;
  op: "gte" | "lte" | "not_null";
  val?: number;
}

interface DateFilter {
  col: "first_vc_round_date" | "last_funding_date";
  op: "gte" | "lte" | "not_null";
  val?: string;
}

interface BoolFilter {
  col: "present_in_attio";
  val: boolean;
}

interface SearchParseResult {
  tag_filters: TagFilter[];
  multitag_filters: MultitagFilter[];
  text_filters: TextFilter[];
  number_filters: NumberFilter[];
  date_filters: DateFilter[];
  bool_filters: BoolFilter[];
  semantic_query: string | null;
  limit?: number;
  reasoning?: string;
}

type SourcingRow = Record<string, unknown> & { similarity?: number };

// ---------------------------------------------------------------------------
// Gemini embedding REST call with retry
// ---------------------------------------------------------------------------

const RETRYABLE_STATUSES = new Set([408, 429, 500, 503, 504]);

async function embedWithGemini(
  geminiApiKey: string,
  text: string,
  maxAttempts = 6,
): Promise<number[]> {
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent?key=${geminiApiKey}`;

  const requestBody = {
    content: { parts: [{ text }] },
    taskType: "RETRIEVAL_QUERY",
    outputDimensionality: 1536,
  };

  let lastError: Error = new Error("Max retries exceeded");

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    if (attempt > 0) {
      const delayMs = Math.min(4 * Math.pow(2, attempt - 1), 60) * 1000;
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }

    const response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(requestBody),
    });

    if (!response.ok) {
      if (RETRYABLE_STATUSES.has(response.status) && attempt < maxAttempts - 1) {
        lastError = new Error(
          `Gemini embedding API returned ${response.status}, retrying`,
        );
        continue;
      }
      const errorText = await response.text();
      throw new Error(
        `Gemini embedding API error: ${response.status} ${errorText}`,
      );
    }

    const result = await response.json();
    const values: number[] | undefined = result?.embedding?.values;

    if (!values || values.length !== 1536) {
      throw new Error(
        `Unexpected embedding response: got ${values?.length ?? 0} dimensions`,
      );
    }

    return values;
  }

  throw lastError;
}

// ---------------------------------------------------------------------------
// Filter application helper
// ---------------------------------------------------------------------------

// "domain" in the filter schema maps to "website" in sourcing_view
function resolveCol(col: string): string {
  return col === "domain" ? "website" : col;
}

// deno-lint-ignore no-explicit-any
function applyFilters(query: any, parsed: SearchParseResult): any {
  for (const f of parsed.tag_filters) {
    const col = resolveCol(f.col);
    if (f.op === "in" && f.val?.length) {
      query = query.in(col, f.val);
    } else if (f.op === "not_null") {
      query = query.not(col, "is", null);
    }
  }

  for (const f of parsed.multitag_filters) {
    const col = resolveCol(f.col);
    if (f.op === "contains" && f.val?.length) {
      query = query.overlaps(col, f.val);
    } else if (f.op === "not_empty") {
      query = query.not(col, "eq", "{}");
    }
  }

  for (const f of parsed.text_filters) {
    const col = resolveCol(f.col);
    if (f.op === "contains" && f.val != null) {
      query = query.ilike(col, `%${f.val}%`);
    } else if (f.op === "not_null") {
      query = query.not(col, "is", null);
    }
  }

  for (const f of parsed.number_filters) {
    const col = resolveCol(f.col);
    if (f.op === "gte" && f.val != null) {
      query = query.gte(col, f.val);
    } else if (f.op === "lte" && f.val != null) {
      query = query.lte(col, f.val);
    } else if (f.op === "not_null") {
      query = query.not(col, "is", null);
    }
  }

  for (const f of parsed.date_filters) {
    const col = resolveCol(f.col);
    if (f.op === "gte" && f.val != null) {
      query = query.gte(col, f.val);
    } else if (f.op === "lte" && f.val != null) {
      query = query.lte(col, f.val);
    } else if (f.op === "not_null") {
      query = query.not(col, "is", null);
    }
  }

  for (const f of parsed.bool_filters) {
    const col = resolveCol(f.col);
    query = query.eq(col, f.val);
  }

  return query;
}

// ---------------------------------------------------------------------------
// Cohere rerank
// ---------------------------------------------------------------------------

async function cohereRerank(
  cohereApiKey: string,
  semanticQuery: string,
  rows: SourcingRow[],
): Promise<{ rows: SourcingRow[]; reranked: boolean }> {
  try {
    const documents = rows.map((row) =>
      [row.description, row.detailed_solution, row.use_cases]
        .filter(Boolean)
        .join(" ") || ""
    );

    const response = await fetch("https://api.cohere.com/v2/rerank", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${cohereApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "rerank-v3.5",
        query: semanticQuery,
        documents,
        top_n: rows.length,
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error(`Cohere rerank error: ${response.status} ${errorText}`);
      return { rows, reranked: false };
    }

    const result = await response.json();
    const rerankedIndices: number[] = (result.results ?? []).map(
      (r: { index: number }) => r.index,
    );

    if (rerankedIndices.length !== rows.length) {
      console.error(
        `Cohere returned ${rerankedIndices.length} results for ${rows.length} documents`,
      );
      return { rows, reranked: false };
    }

    const rerankedRows = rerankedIndices.map((idx) => rows[idx]);
    return { rows: rerankedRows, reranked: true };
  } catch (err) {
    console.error("Cohere rerank failed, returning original order:", err);
    return { rows, reranked: false };
  }
}

// ---------------------------------------------------------------------------
// Request handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    let body: unknown;
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ success: false, error: "Invalid JSON body" }, 400);
    }

    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return jsonResponse(
        { success: false, error: "Request body must be a JSON object" },
        400,
      );
    }

    const parsed = body as Record<string, unknown>;

    // Basic shape validation
    if (
      !Array.isArray(parsed.tag_filters) ||
      !Array.isArray(parsed.multitag_filters) ||
      !Array.isArray(parsed.text_filters) ||
      !Array.isArray(parsed.number_filters) ||
      !Array.isArray(parsed.date_filters) ||
      !Array.isArray(parsed.bool_filters)
    ) {
      return jsonResponse(
        {
          success: false,
          error:
            "Missing required filter arrays: tag_filters, multitag_filters, text_filters, number_filters, date_filters, bool_filters",
        },
        400,
      );
    }

    // semantic_query is required
    if (parsed.semantic_query === null || parsed.semantic_query === undefined) {
      return jsonResponse(
        { success: false, error: "semantic_query is required" },
        400,
      );
    }

    const searchParseResult = parsed as unknown as SearchParseResult;

    // Environment variables
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const geminiApiKey = Deno.env.get("GEMINI_API_KEY");
    const cohereApiKey = Deno.env.get("COHERE_API_KEY");

    if (!geminiApiKey) {
      throw new Error("GEMINI_API_KEY is not set");
    }
    if (!cohereApiKey) {
      throw new Error("COHERE_API_KEY is not set");
    }

    // Step 1: Embed the semantic query
    const embeddingVector = await embedWithGemini(
      geminiApiKey,
      searchParseResult.semantic_query as string,
    );

    // Step 2: Vector search via match_companies RPC + filter chaining
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    let query = supabase
      .rpc("match_companies", { query_embedding: embeddingVector })
      .order("similarity", { ascending: false })
      .limit(1000);

    query = applyFilters(query, searchParseResult);

    const { data, error } = await query;

    if (error) {
      throw new Error(`Database query failed: ${error.message}`);
    }

    let results: SourcingRow[] = (data ?? []) as SourcingRow[];

    // Step 3: Cohere rerank
    const { rows: rerankedRows, reranked } = await cohereRerank(
      cohereApiKey,
      searchParseResult.semantic_query as string,
      results,
    );
    results = rerankedRows;

    // Step 4: Apply limit
    const limit = searchParseResult.limit ?? 1000;
    const finalResults = results.slice(0, limit);

    return jsonResponse({
      success: true,
      results: finalResults,
      count: finalResults.length,
      reranked,
    });
  } catch (error) {
    return jsonResponse({ success: false, error: error.message }, 500);
  }
});
