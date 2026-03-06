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
// TypeScript types (ported from filter_schema.py)
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
  reasoning: string;
}

// ---------------------------------------------------------------------------
// Gemini response schema (mirrors Pydantic models as OpenAPI/Gemini schema)
// ---------------------------------------------------------------------------

const RESPONSE_SCHEMA = {
  type: "OBJECT",
  description:
    "Structured output returned by the AI search query parser. All filter lists default to empty. Filters across different lists are combined with AND.",
  properties: {
    tag_filters: {
      type: "ARRAY",
      description:
        "Filters on single-value enum columns. All filters are AND-ed together.",
      items: {
        type: "OBJECT",
        properties: {
          col: {
            type: "STRING",
            description: "Name of the tag column to filter on.",
            enum: [
              "fund_prime_scope",
              "hq_city",
              "gtm_target_cg",
              "gtm_target_by",
              "vc_current_stage",
              "business_model",
              "primary_sector_served_cg",
              "primary_industry_served_cg",
              "primary_sector_served_by",
              "primary_industry_served_by",
              "business_mapping",
              "last_stage_in_attio",
              "last_status_in_attio",
            ],
          },
          op: {
            type: "STRING",
            description:
              "'in' keeps rows whose column value is one of val. 'not_null' keeps rows where the column is not null (val is ignored).",
            enum: ["in", "not_null"],
          },
          val: {
            type: "ARRAY",
            description:
              "One or more allowed values. Required when op is 'in'. Must be chosen from the column's known values.",
            nullable: true,
            items: { type: "STRING" },
          },
        },
        required: ["col", "op"],
      },
    },
    multitag_filters: {
      type: "ARRAY",
      description: "Filters on array (multi-value tag) columns.",
      items: {
        type: "OBJECT",
        properties: {
          col: {
            type: "STRING",
            description: "Name of the multitag (array) column to filter on.",
            enum: [
              "hq_country",
              "global_2000_clients",
              "cg_key_platforms",
              "by_key_platforms",
              "competitors_cg",
              "competitors_by",
              "affiliates_cg",
              "affiliates_by",
              "all_investors",
              "last_round_lead_investors",
              "all_industries_served",
              "tech_tags",
            ],
          },
          op: {
            type: "STRING",
            description:
              "'contains' keeps rows where the array overlaps with val (at least one match). 'not_empty' keeps rows where the array is not null and not empty (val is ignored).",
            enum: ["contains", "not_empty"],
          },
          val: {
            type: "ARRAY",
            description:
              "Values to match against. Required when op is 'contains'. Must be chosen from the column's known values.",
            nullable: true,
            items: { type: "STRING" },
          },
        },
        required: ["col", "op"],
      },
    },
    text_filters: {
      type: "ARRAY",
      description: "Substring filters on free-text columns (name, domain).",
      items: {
        type: "OBJECT",
        properties: {
          col: {
            type: "STRING",
            description: "Name of the text column to filter on.",
            enum: ["name", "domain"],
          },
          op: {
            type: "STRING",
            description:
              "'contains' keeps rows where col contains val (case-insensitive substring match). 'not_null' keeps rows where the column is not null (val is ignored).",
            enum: ["contains", "not_null"],
          },
          val: {
            type: "STRING",
            description:
              "Substring to search for. Required when op is 'contains'. Do not add % wildcards.",
            nullable: true,
          },
        },
        required: ["col", "op"],
      },
    },
    number_filters: {
      type: "ARRAY",
      description: "Numeric comparison filters.",
      items: {
        type: "OBJECT",
        properties: {
          col: {
            type: "STRING",
            description: "Name of the numeric column to filter on.",
            enum: [
              "inc_date",
              "number_of_clients_identified",
              "first_vc_round_amount",
              "total_amount_raised",
              "last_funding_amount",
              "total_nber_of_rounds",
              "solution_fit_cg",
              "solution_fit_by",
              "business_fit_cg",
              "business_fit_by",
              "maturity_fit",
              "equity_score",
              "traction_score",
              "global_fund_score",
              "headcount",
              "headcount_growth_l12m",
              "web_traffic",
              "web_traffic_growth_l12m",
            ],
          },
          op: {
            type: "STRING",
            description:
              "'gte' keeps rows where col >= val. 'lte' keeps rows where col <= val. 'not_null' keeps rows where the column is not null (val is ignored). Combine gte + lte filters on the same column to express a range.",
            enum: ["gte", "lte", "not_null"],
          },
          val: {
            type: "NUMBER",
            description:
              "The comparison value. Required when op is 'gte' or 'lte'.",
            nullable: true,
          },
        },
        required: ["col", "op"],
      },
    },
    date_filters: {
      type: "ARRAY",
      description: "Date comparison filters.",
      items: {
        type: "OBJECT",
        properties: {
          col: {
            type: "STRING",
            description: "Name of the date column to filter on.",
            enum: ["first_vc_round_date", "last_funding_date"],
          },
          op: {
            type: "STRING",
            description:
              "'gte' keeps rows where col >= val. 'lte' keeps rows where col <= val. 'not_null' keeps rows where the column is not null (val is ignored). Combine gte + lte filters on the same column to express a date range.",
            enum: ["gte", "lte", "not_null"],
          },
          val: {
            type: "STRING",
            description:
              "ISO 8601 date string (YYYY-MM-DD). Required when op is 'gte' or 'lte'.",
            nullable: true,
          },
        },
        required: ["col", "op"],
      },
    },
    bool_filters: {
      type: "ARRAY",
      description: "Boolean equality filters.",
      items: {
        type: "OBJECT",
        properties: {
          col: {
            type: "STRING",
            description: "Name of the boolean column to filter on.",
            enum: ["present_in_attio", "serial_entrepreneur"],
          },
          val: {
            type: "BOOLEAN",
            description:
              "true to keep matching rows, false to keep non-matching rows.",
          },
        },
        required: ["col", "val"],
      },
    },
    limit: {
      type: "INTEGER",
      description:
        "Maximum number of results to return. Extract from the query if the user specifies a count (e.g. 'show me 50 companies', 'top 20'). Must be between 10 and 100. Default to 100 if the user does not specify a count.",
      minimum: 10,
      maximum: 100,
    },
    semantic_query: {
      type: "STRING",
      nullable: true,
      description:
        "A reformulated, clean semantic search query capturing the descriptive intent of the user's request (product description, technology, use case, target customer narrative). Null if the query is purely filter-based.",
    },
    reasoning: {
      type: "STRING",
      description:
        "Brief chain-of-thought: what was interpreted as a filter, what was kept for semantic search, and why.",
    },
  },
  required: [
    "tag_filters",
    "multitag_filters",
    "text_filters",
    "number_filters",
    "date_filters",
    "bool_filters",
    "reasoning",
  ],
};

// ---------------------------------------------------------------------------
// System prompt (ported from build_question.py)
// ---------------------------------------------------------------------------

const SYSTEM_PROMPT = `**Role:**
You are an expert search query parser for ISAI, a VC firm sourcing B2B software
companies (ISAI Cap Venture / Capgemini ecosystem) and ConTech / PropTech companies
(ISAI Build Venture / VINCI / Bouygues ecosystem).

**Objective:**
Parse the analyst's free-text search query into a SearchParseResult JSON object
containing two things:
  1. Structured SQL filters (tag, multitag, text, number, date, bool) against the
     sourcing table columns.
  2. A semantic_query – a clean, descriptive query for embedding-based search over
     company documents (description + detailed solution + use cases). Set to null
     if the query is purely filter-based.

**Sourcing Table – Column Reference:**
  Tag columns (single-value enum):
    - fund_prime_scope: which ISAI fund the company primarily targets
    - hq_city: city where the company is headquartered
    - gtm_target_cg: go-to-market target in the Capgemini ecosystem
    - gtm_target_by: go-to-market target in the VINCI/Build ecosystem
    - vc_current_stage: current funding stage (e.g. Seed, Series A, Series B)
    - business_model: company's business model
    - primary_sector_served_cg: primary sector served (Capgemini lens)
    - primary_industry_served_cg: primary industry served (Capgemini lens)
    - primary_sector_served_by: primary sector served (Build/VINCI lens)
    - primary_industry_served_by: primary industry served (Build/VINCI lens)
    - business_mapping: business mapping category
    - last_stage_in_attio: last pipeline stage recorded in the CRM
    - last_status_in_attio: last status recorded in the CRM

  Multitag columns (array, multi-value):
    - hq_country: countries where the company is headquartered (array)
    - global_2000_clients: Forbes Global 2000 clients of the company
    - cg_key_platforms: key Capgemini platforms the company integrates with
    - by_key_platforms: key VINCI/Build platforms the company integrates with
    - competitors_cg: known competitors in the Capgemini ecosystem
    - competitors_by: known competitors in the Build/VINCI ecosystem
    - affiliates_cg: Capgemini affiliates associated with the company
    - affiliates_by: VINCI affiliates associated with the company
    - all_investors: all investors that have backed the company
    - last_round_lead_investors: lead investors in the most recent funding round
    - all_industries_served: all industries the company serves
    - tech_tags: technology tags describing the company's tech stack / approach

  Text columns (free-text substring match):
    - name: company name
    - domain: company website domain

  Number columns:
    - inc_date: incorporation year (4-digit integer)
    - number_of_clients_identified: number of identified clients
    - first_vc_round_amount: amount raised in the first VC round (USD)
    - total_amount_raised: total funding raised across all rounds (USD)
    - last_funding_amount: amount raised in the most recent round (USD)
    - total_nber_of_rounds: total number of funding rounds
    - solution_fit_cg: solution fit score for Cap Venture (1=best, 4=worst)
    - solution_fit_by: solution fit score for Build Venture (1=best, 4=worst)
    - business_fit_cg: business fit score for Cap Venture (1=best, 4=worst)
    - business_fit_by: business fit score for Build Venture (1=best, 4=worst)
    - maturity_fit: maturity fit score (1=best, 4=worst)
    - equity_score: equity score (1=best, 4=worst)
    - traction_score: traction score (1=best, 4=worst)
    - global_fund_score: overall fund fit score (1=best, 4=worst)
    - headcount: total employee count (integer, from Dealroom)
    - headcount_growth_l12m: employee headcount growth over last 12 months, as a percentage (e.g. 25.5 for 25.5%, from Dealroom)
    - web_traffic: monthly web traffic visits (integer, from Dealroom)
    - web_traffic_growth_l12m: web traffic growth over last 12 months, as a percentage (e.g. 25.5 for 25.5%, from Dealroom)

  Date columns (ISO 8601: YYYY-MM-DD):
    - first_vc_round_date: date of the first VC round
    - last_funding_date: date of the most recent funding round

  Boolean columns:
    - present_in_attio: true if the company is tracked in the CRM
    - serial_entrepreneur: true if at least one founder is a serial entrepreneur

**Filter Rules:**
  - Use \`in\` / \`contains\` when the analyst names specific known values.
  - Use \`gte\` / \`lte\` to express numeric or date bounds; emit two filters for ranges. Be careful with amounts, they are in USD. So 1M is 1000000.
  - Use \`not_null\` / \`not_empty\` to express "has a value" constraints.
  - ALL filters are combined with AND.
  - Values for tag and multitag columns MUST come from the lists provided below.
  - Set \`limit\` to the count explicitly mentioned by the user (e.g. "top 50", "show 20"); clamp to the range [10, 100]. Default to 100 if no count is mentioned.

**Semantic Search Guidance:**
  The embedded documents are each company's: description, detailed solution, and
  use cases. The semantic_query should describe the product, technology, or use-case
  narrative in plain English – not the company's geography or stage (those are filters).

**Output:**
Return only a valid JSON object following the SearchParseResult schema. Include a
concise \`reasoning\` field explaining your choices.`;

// ---------------------------------------------------------------------------
// Filter values section builder (ported from build_question.py)
// ---------------------------------------------------------------------------

function buildFilterValuesSection(filterValues: {
  tag_columns?: Record<string, string[]>;
  multitag_columns?: Record<string, string[]>;
}): string {
  const lines: string[] = [];

  lines.push("## Tag Column Possible Values");
  for (const [col, values] of Object.entries(filterValues.tag_columns ?? {})) {
    lines.push(`- ${col}: ${values.join(", ")}`);
  }

  lines.push("");
  lines.push("## Multitag Column Possible Values");
  for (
    const [col, values] of Object.entries(filterValues.multitag_columns ?? {})
  ) {
    lines.push(`- ${col}: ${values.join(", ")}`);
  }

  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Gemini REST API call with retry
// ---------------------------------------------------------------------------

const RETRYABLE_STATUSES = new Set([408, 429, 500, 503, 504]);
const GEMINI_MODEL = "gemini-3-pro-preview";

async function callGeminiWithRetry(
  token: string,
  project: string,
  location: string,
  systemPrompt: string,
  userQuery: string,
  maxAttempts = 6,
): Promise<SearchParseResult> {
  const url =
    `https://aiplatform.googleapis.com/v1/projects/${project}/locations/${location}/publishers/google/models/${GEMINI_MODEL}:generateContent`;

  const requestBody = {
    system_instruction: { parts: [{ text: systemPrompt }] },
    contents: [
      {
        role: "user",
        parts: [
          {
            text:
              `# Content Provided\nUser query: ${userQuery}\n\n# Question\nParse this search query into structured SQL filters and a semantic search query.`,
          },
        ],
      },
    ],
    generationConfig: {
      responseMimeType: "application/json",
      responseSchema: RESPONSE_SCHEMA,
      temperature: 0.2,
    },
  };

  let lastError: Error = new Error("Max retries exceeded");

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    if (attempt > 0) {
      const delayMs = Math.min(4 * Math.pow(2, attempt - 1), 60) * 1000;
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }

    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${token}`,
      },
      body: JSON.stringify(requestBody),
    });

    if (!response.ok) {
      if (RETRYABLE_STATUSES.has(response.status) && attempt < maxAttempts - 1) {
        lastError = new Error(`Gemini API returned ${response.status}, retrying`);
        console.error(
          `[parse-free-text-query] ${lastError.message} (attempt ${attempt + 1}/${maxAttempts})`,
        );
        continue;
      }
      const errorText = await response.text();
      throw new Error(`Gemini API error: ${response.status} ${errorText}`);
    }

    const result = await response.json();
    const text = result.candidates?.[0]?.content?.parts?.[0]?.text;

    if (!text) {
      throw new Error("No text content in Gemini response");
    }

    return JSON.parse(text) as SearchParseResult;
  }

  throw lastError;
}

// ---------------------------------------------------------------------------
// Request handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { query } = await req.json();

    if (!query || typeof query !== "string" || query.trim() === "") {
      return jsonResponse(
        { success: false, error: "query is required and must be a non-empty string" },
        400,
      );
    }

    console.log(`[parse-free-text-query] Request received: query="${query.trim()}"`);

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const googleCredentials = Deno.env.get("GOOGLE_CREDENTIALS");
    const googleProject = Deno.env.get("GOOGLE_CLOUD_PROJECT");
    const googleLocation = Deno.env.get("GOOGLE_CLOUD_LOCATION") ?? "global";
    const searchResourcesBucket = Deno.env.get("SEARCH_RESOURCES_BUCKET_NAME");

    if (!googleCredentials) {
      throw new Error("GOOGLE_CREDENTIALS is not set");
    }
    if (!googleProject) {
      throw new Error("GOOGLE_CLOUD_PROJECT is not set");
    }
    if (!searchResourcesBucket) {
      throw new Error("SEARCH_RESOURCES_BUCKET_NAME is not set");
    }

    // Obtain short-lived OAuth2 token
    const token = await getGoogleAccessToken(googleCredentials, [
      "https://www.googleapis.com/auth/cloud-platform",
    ]);

    // Load filter values from Supabase Storage
    console.log(`[parse-free-text-query] Loading filter values from storage...`);
    const supabase = createClient(supabaseUrl, supabaseServiceKey);
    const { data: fileData, error: downloadError } = await supabase.storage
      .from(searchResourcesBucket)
      .download("search_tag_and_multitag_values.json");

    if (downloadError || !fileData) {
      throw new Error(
        `Failed to download filter values: ${downloadError?.message ?? "no data returned"}`,
      );
    }

    const filterValues = JSON.parse(await fileData.text());

    // Build full system prompt with filter values appended
    const systemPrompt =
      SYSTEM_PROMPT + "\n\n" + buildFilterValuesSection(filterValues);

    // Call Gemini with retry
    console.log(
      `[parse-free-text-query] Calling Gemini (${GEMINI_MODEL}) to parse query...`,
    );
    const result = await callGeminiWithRetry(
      token,
      googleProject,
      googleLocation,
      systemPrompt,
      query.trim(),
    );

    if (!result.limit && result.semantic_query !== null) {
      result.limit = 100;
    }

    console.log(
      `[parse-free-text-query] Parsed successfully: semantic_query="${result.semantic_query}" limit=${result.limit} tag_filters=${result.tag_filters.length} multitag_filters=${result.multitag_filters.length} number_filters=${result.number_filters.length}`,
    );

    return jsonResponse({ success: true, result });
  } catch (error) {
    console.error("[parse-free-text-query] Unhandled error:", error);
    return jsonResponse({ success: false, error: error.message }, 500);
  }
});
