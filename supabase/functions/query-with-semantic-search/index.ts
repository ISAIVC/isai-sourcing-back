import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { getGoogleAccessToken } from "../_shared/google-auth.ts";

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
  | "hq_country"
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
  | "global_fund_score"
  | "headcount"
  | "headcount_growth_l12m"
  | "web_traffic"
  | "web_traffic_growth_l12m";

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
  col: "present_in_attio" | "serial_entrepreneur";
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

const GEMINI_TIMEOUT_MS = 15_000;

async function embedWithGemini(
  token: string,
  project: string,
  location: string,
  text: string,
  maxAttempts = 6,
): Promise<number[]> {
  const url =
    `https://aiplatform.googleapis.com/v1/projects/${project}/locations/${location}/publishers/google/models/gemini-embedding-001:predict`;

  const requestBody = {
    instances: [{ content: text, task_type: "RETRIEVAL_QUERY" }],
    parameters: { outputDimensionality: 768 },
  };

  let lastError: Error = new Error("Max retries exceeded");

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    if (attempt > 0) {
      const delayMs = Math.min(4 * Math.pow(2, attempt - 1), 60) * 1000;
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), GEMINI_TIMEOUT_MS);

    let response: Response;
    try {
      response = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${token}`,
        },
        body: JSON.stringify(requestBody),
        signal: controller.signal,
      });
    } catch (err) {
      clearTimeout(timeoutId);
      const isTimeout = err instanceof Error && err.name === "AbortError";
      lastError = new Error(
        isTimeout
          ? `Gemini embedding timed out after ${GEMINI_TIMEOUT_MS}ms (attempt ${attempt + 1})`
          : `Gemini embedding fetch failed: ${err}`,
      );
      console.error(lastError.message);
      if (attempt < maxAttempts - 1) continue;
      throw lastError;
    }
    clearTimeout(timeoutId);

    if (!response.ok) {
      if (RETRYABLE_STATUSES.has(response.status) && attempt < maxAttempts - 1) {
        lastError = new Error(
          `Gemini embedding API returned ${response.status}, retrying (attempt ${attempt + 1})`,
        );
        console.error(lastError.message);
        continue;
      }
      const errorText = await response.text();
      throw new Error(
        `Gemini embedding API error: ${response.status} ${errorText}`,
      );
    }

    const result = await response.json();
    const values: number[] | undefined = result?.predictions?.[0]?.embeddings?.values;

    if (!values || values.length !== 768) {
      lastError = new Error(
        `Unexpected embedding response: got ${values?.length ?? 0} dimensions (attempt ${attempt + 1})`,
      );
      console.error(lastError.message);
      if (attempt < maxAttempts - 1) continue;
      throw lastError;
    }

    return values;
  }

  throw lastError;
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

    // semantic_query is required and must be a non-empty string
    if (
      parsed.semantic_query === null ||
      parsed.semantic_query === undefined ||
      typeof parsed.semantic_query !== "string" ||
      parsed.semantic_query.trim() === ""
    ) {
      return jsonResponse(
        { success: false, error: "semantic_query must be a non-empty string" },
        400,
      );
    }

    const semanticQuery = parsed.semantic_query as string;
    const searchParseResult = parsed as unknown as SearchParseResult;

    // Environment variables
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const googleCredentials = Deno.env.get("GOOGLE_CREDENTIALS");
    const googleProject = Deno.env.get("GOOGLE_CLOUD_PROJECT");
    const googleLocation = Deno.env.get("GOOGLE_CLOUD_LOCATION") ?? "global";
    const cohereApiKey = Deno.env.get("COHERE_API_KEY");

    if (!googleCredentials) {
      throw new Error("GOOGLE_CREDENTIALS is not set");
    }
    if (!googleProject) {
      throw new Error("GOOGLE_CLOUD_PROJECT is not set");
    }
    if (!cohereApiKey) {
      throw new Error("COHERE_API_KEY is not set");
    }

    // Obtain short-lived OAuth2 token
    const token = await getGoogleAccessToken(googleCredentials, [
      "https://www.googleapis.com/auth/cloud-platform",
    ]);

    const filterCounts = [
      parsed.tag_filters.length,
      parsed.multitag_filters.length,
      parsed.text_filters.length,
      parsed.number_filters.length,
      parsed.date_filters.length,
      parsed.bool_filters.length,
    ].reduce((a, b) => a + b, 0);
    console.log(
      `[query-with-semantic-search] Request received: semantic_query="${semanticQuery}" total_filters=${filterCounts} limit=${searchParseResult.limit ?? 1000}`,
    );

    // Step 1: Embed the semantic query
    console.log("[1/4] Embedding semantic query...");
    const embeddingVector = await embedWithGemini(
      token,
      googleProject,
      googleLocation,
      semanticQuery,
    );
    console.log("[1/4] Embedding done.");

    // Step 2: Vector search via match_companies_filtered RPC (filters + ORDER BY + LIMIT in one query)
    console.log("[2/4] Running match_companies_filtered RPC...");
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const filtersJsonb = {
      tag_filters:      searchParseResult.tag_filters,
      multitag_filters: searchParseResult.multitag_filters,
      text_filters:     searchParseResult.text_filters,
      number_filters:   searchParseResult.number_filters,
      date_filters:     searchParseResult.date_filters,
      bool_filters:     searchParseResult.bool_filters,
    };

    const { data, error } = await supabase.rpc("match_companies_filtered", {
      p_embedding: embeddingVector,
      p_filters:   filtersJsonb,
      p_limit:     searchParseResult.limit ?? 1000,
    });

    if (error) {
      throw new Error(`Database query failed: ${error.message}`);
    }
    console.log(`[2/4] RPC returned ${(data ?? []).length} rows.`);

    let results: SourcingRow[] = (data ?? []) as SourcingRow[];

    // Step 3: Cohere rerank
    console.log("[3/4] Reranking with Cohere...");
    const { rows: rerankedRows, reranked } = await cohereRerank(
      cohereApiKey,
      semanticQuery,
      results,
    );
    results = rerankedRows;
    console.log(`[3/4] Rerank done (reranked=${reranked}).`);

    // Step 4: Apply limit
    const limit = searchParseResult.limit ?? 1000;
    const finalResults = results.slice(0, limit);
    console.log(`[4/4] Returning ${finalResults.length} results.`);

    return jsonResponse({
      success: true,
      results: finalResults,
      count: finalResults.length,
      reranked,
    });
  } catch (error) {
    console.error("[query-with-semantic-search] Unhandled error:", error);
    return jsonResponse({ success: false, error: error.message }, 500);
  }
});
