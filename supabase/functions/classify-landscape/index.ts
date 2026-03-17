import "jsr:@supabase/functions-js/edge-runtime.d.ts";
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
// Types
// ---------------------------------------------------------------------------

interface Company {
  name: string;
  detailed_solution?: string | null;
  use_cases?: string | null;
}

interface ClassificationResult {
  company_name: string;
  sector: string;
  subsector: string;
}

// ---------------------------------------------------------------------------
// Gemini call with retry
// ---------------------------------------------------------------------------

const RETRYABLE_STATUSES = new Set([408, 429, 500, 503, 504]);
const GEMINI_MODEL = "gemini-3-flash-preview";

const RESPONSE_SCHEMA = {
  type: "object",
  properties: {
    sectors: {
      type: "array",
      items: {
        type: "object",
        properties: {
          sector: { type: "string" },
          subsectors: {
            type: "array",
            items: {
              type: "object",
              properties: {
                subsector: { type: "string" },
                companies: { type: "array", items: { type: "string" } },
              },
              required: ["subsector", "companies"],
            },
          },
        },
        required: ["sector", "subsectors"],
      },
    },
  },
  required: ["sectors"],
};

const SYSTEM_PROMPT = `You are a market analyst. Analyze the following companies and group them into natural market clusters.
Return ONLY strict JSON. No explanation, no markdown.
Generate 5 to 8 sectors. Each sector must have 2 to 5 subsectors.
Every company must belong to exactly one subsector.
JSON structure: { "sectors": [{ "sector": "...", "subsectors": [{ "subsector": "...", "companies": ["..."] }] }] }`;

async function callGeminiWithRetry(
  token: string,
  project: string,
  location: string,
  companies: Company[],
  maxAttempts = 6,
): Promise<ClassificationResult[]> {
  const url =
    `https://aiplatform.googleapis.com/v1/projects/${project}/locations/${location}/publishers/google/models/${GEMINI_MODEL}:generateContent`;

  const userMessage = companies
    .map((c) =>
      `Company: ${c.name}\nDetailed solution: ${c.detailed_solution || "N/A"}\nUse cases: ${c.use_cases || "N/A"}`
    )
    .join("\n\n");

  const requestBody = {
    system_instruction: { parts: [{ text: SYSTEM_PROMPT }] },
    contents: [{ role: "user", parts: [{ text: userMessage }] }],
    generationConfig: {
      responseMimeType: "application/json",
      responseSchema: RESPONSE_SCHEMA,
      temperature: 0.3,
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
          `[classify-landscape] ${lastError.message} (attempt ${attempt + 1}/${maxAttempts})`,
        );
        continue;
      }
      const errorText = await response.text();
      throw new Error(`Gemini API error: ${response.status} ${errorText}`);
    }

    const result = await response.json();
    const text = result.candidates?.[0]?.content?.parts?.[0]?.text;
    if (!text) throw new Error("No text content in Gemini response");

    const parsed = JSON.parse(text);

    // Flatten sectors → subsectors → companies into flat mapping
    const mapping: ClassificationResult[] = [];
    for (const s of parsed.sectors ?? []) {
      for (const sub of s.subsectors ?? []) {
        for (const companyName of sub.companies ?? []) {
          mapping.push({ company_name: companyName, sector: s.sector, subsector: sub.subsector });
        }
      }
    }
    return mapping;
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
    const { companies } = await req.json();

    if (!Array.isArray(companies) || companies.length === 0) {
      return jsonResponse({ error: "companies must be a non-empty array" }, 400);
    }

    const googleCredentials = Deno.env.get("GOOGLE_CREDENTIALS");
    const googleProject = Deno.env.get("GOOGLE_CLOUD_PROJECT");
    const googleLocation = Deno.env.get("GOOGLE_CLOUD_LOCATION") ?? "global";

    if (!googleCredentials) throw new Error("GOOGLE_CREDENTIALS is not set");
    if (!googleProject) throw new Error("GOOGLE_CLOUD_PROJECT is not set");

    const token = await getGoogleAccessToken(JSON.parse(googleCredentials));

    const classification = await callGeminiWithRetry(
      token,
      googleProject,
      googleLocation,
      companies as Company[],
    );

    console.log(`[classify-landscape] Classified ${companies.length} companies into ${classification.length} entries`);

    return jsonResponse({ classification });
  } catch (err) {
    console.error("[classify-landscape] Error:", err);
    return jsonResponse({ error: (err as Error).message }, 500);
  }
});
