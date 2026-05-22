import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import * as XLSX from "https://cdn.sheetjs.com/xlsx-0.20.3/package/xlsx.mjs";

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

function extractDomainsFromCompaniesSheet(fileBuffer: ArrayBuffer): string[] {
  const data = new Uint8Array(fileBuffer);

  // First pass: cheap metadata-only read to find the Companies sheet name.
  // Tracxn exports have 15 sheets (with images/drawings); parsing all of them
  // exceeds the Edge Function CPU time limit. We only need one sheet.
  const meta = XLSX.read(data, { type: "array", bookSheets: true });
  const companiesSheetName = meta.SheetNames.find((name: string) =>
    name.startsWith("Companies")
  );

  if (!companiesSheetName) {
    throw new Error("No sheet starting with 'Companies' found in the file");
  }

  // Second pass: parse only the Companies sheet.
  // Disable styles/formulas/HTML — we only need raw cell values (saves memory).
  const workbook = XLSX.read(data, {
    type: "array",
    sheets: companiesSheetName,
    cellStyles: false,
    cellFormula: false,
    cellHTML: false,
    cellDates: false,
    raw: true,
  });

  const sheet = workbook.Sheets[companiesSheetName];

  // Fix broken dimension ref (Tracxn exports use <dimension ref="A1"/>).
  // Recompute !ref from actual cell keys to know the real extent of the sheet.
  const cellKeys = Object.keys(sheet).filter((k) => !k.startsWith("!"));
  let maxR = 0, maxC = 0;
  for (const k of cellKeys) {
    try {
      const addr = XLSX.utils.decode_cell(k);
      if (addr.r > maxR) maxR = addr.r;
      if (addr.c > maxC) maxC = addr.c;
    } catch (_) { /* skip non-cell keys */ }
  }
  if (cellKeys.length > 0) {
    sheet["!ref"] = XLSX.utils.encode_range({ r: 0, c: 0 }, { r: maxR, c: maxC });
  }

  // Find header row + domain column by direct cell scanning.
  // Avoids sheet_to_json which duplicates the entire sheet in memory.
  // Tracxn occasionally adds metadata lines that shift the header row down.
  let headerRowIdx = -1;
  let domainColIdx = -1;
  outer: for (let r = 0; r <= Math.min(maxR, 20); r++) {
    for (let c = 0; c <= Math.min(maxC, 30); c++) {
      const cell = sheet[XLSX.utils.encode_cell({ r, c })];
      if (cell?.v === "Domain Name") {
        headerRowIdx = r;
        domainColIdx = c;
        break outer;
      }
    }
  }

  if (headerRowIdx === -1 || domainColIdx === -1) {
    throw new Error("Could not find a header row containing 'Domain Name'");
  }

  // Extract only the domain column via direct cell access.
  const domains: string[] = [];
  for (let r = headerRowIdx + 1; r <= maxR; r++) {
    const cell = sheet[XLSX.utils.encode_cell({ r, c: domainColIdx })];
    if (cell && typeof cell.v === "string" && cell.v.trim()) {
      domains.push(cell.v.trim());
    }
  }

  return [...new Set(domains)];
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { file_path } = await req.json();

    if (!file_path) {
      return jsonResponse(
        { success: false, error: "file_path is required" },
        400
      );
    }

    console.log(
      `[assess-db-changes] Request received: file_path=${file_path}`,
    );

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const bucketName = Deno.env.get("TRAXCN_EXPORTS_BUCKET_NAME");

    if (!bucketName) {
      throw new Error("TRAXCN_EXPORTS_BUCKET_NAME is not set");
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    console.log(
      `[assess-db-changes] Downloading file from bucket: ${bucketName}/${file_path}`,
    );

    const { data: fileData, error: downloadError } = await supabase.storage
      .from(bucketName)
      .download(file_path);

    if (downloadError || !fileData) {
      throw new Error(
        `Failed to download file '${file_path}': ${downloadError?.message}`
      );
    }

    console.log(`[assess-db-changes] File downloaded, extracting domains...`);

    const fileBuffer = await fileData.arrayBuffer();
    const domains = extractDomainsFromCompaniesSheet(fileBuffer);

    console.log(
      `[assess-db-changes] Extracted ${domains.length} unique domains from file`,
    );

    if (!domains.length) {
      console.log(`[assess-db-changes] No domains found, returning early`);
      return jsonResponse({
        success: true,
        number_of_companies_to_add: 0,
        number_of_companies_to_update: 0,
        new_domains: [],
        existing_domains: [],
      });
    }

    const { data: existingRecords, error: queryError } = await supabase
      .from("traxcn_companies")
      .select("domain_name")
      .in("domain_name", domains)
      .limit(2000);

    if (queryError) {
      throw new Error(
        `Failed to query existing domains: ${queryError.message}`
      );
    }

    const existingDomains = new Set(
      existingRecords.map((r: { domain_name: string }) => r.domain_name)
    );
    const newDomains = domains.filter((d) => !existingDomains.has(d));

    console.log(
      `[assess-db-changes] DB diff complete: ${newDomains.length} to add, ${existingDomains.size} to update`,
    );

    return jsonResponse({
      success: true,
      number_of_companies_to_add: newDomains.length,
      number_of_companies_to_update: existingDomains.size,
      new_domains: newDomains,
      existing_domains: [...existingDomains],
    });
  } catch (error) {
    console.error("[assess-db-changes] Unhandled error:", error);
    return jsonResponse({ success: false, error: error.message }, 500);
  }
});
