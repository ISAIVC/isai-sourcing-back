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

  // Second pass: parse only the Companies sheet to stay within CPU limits.
  const workbook = XLSX.read(data, {
    type: "array",
    sheets: companiesSheetName,
  });

  const sheet = workbook.Sheets[companiesSheetName];

  // Tracxn exports use `<dimension ref="A1"/>` (incorrect metadata), which causes
  // SheetJS to set sheet['!ref'] = "A1" and sheet_to_json to only see one cell.
  // Fix: recompute !ref from the actual cell keys present in the sheet object.
  const cellKeys = Object.keys(sheet).filter((k) => !k.startsWith("!"));
  if (cellKeys.length > 0) {
    let maxR = 0, maxC = 0;
    for (const k of cellKeys) {
      try {
        const addr = XLSX.utils.decode_cell(k);
        if (addr.r > maxR) maxR = addr.r;
        if (addr.c > maxC) maxC = addr.c;
      } catch (_) { /* skip non-cell keys */ }
    }
    sheet["!ref"] = XLSX.utils.encode_range(
      { r: 0, c: 0 },
      { r: maxR, c: maxC },
    );
  }

  // Row index 5 (6th row) is the header, matching Python's pd.read_excel(header=5)
  const rows: Record<string, string>[] = XLSX.utils.sheet_to_json(sheet, {
    range: 5,
  });

  const domains = rows
    .map((row) => row["Domain Name"])
    .filter((domain): domain is string =>
      typeof domain === "string" && domain.trim() !== ""
    );

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
      .in("domain_name", domains);

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
