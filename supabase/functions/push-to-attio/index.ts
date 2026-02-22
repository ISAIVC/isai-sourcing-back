import "jsr:@supabase/functions-js/edge-runtime.d.ts";

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

function buildPrefectApiUrl(orgId: string, workspaceId: string): string {
  return `https://api.prefect.cloud/api/accounts/${orgId}/workspaces/${workspaceId}`;
}

function buildFlowRunUrl(
  orgId: string,
  workspaceId: string,
  flowRunId: string,
): string {
  return `https://app.prefect.cloud/account/${orgId}/workspace/${workspaceId}/runs/flow-run/${flowRunId}?preview=true&tab=logs`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { domains, workspace } = await req.json();

    if (
      !domains ||
      !Array.isArray(domains) ||
      domains.length === 0 ||
      !domains.every((d: unknown) => typeof d === "string")
    ) {
      return jsonResponse(
        { success: false, error: "domains must be a non-empty array of strings" },
        400,
      );
    }

    if (workspace !== "cg" && workspace !== "by") {
      return jsonResponse(
        { success: false, error: 'workspace must be "cg" or "by"' },
        400,
      );
    }

    console.log(
      `[push-to-attio] Request received: workspace=${workspace} domains=[${domains.join(", ")}]`,
    );

    const prefectApiKey = Deno.env.get("PREFECT_API_KEY");
    const prefectOrg = Deno.env.get("PREFECT_ORG");
    const prefectWorkspace = Deno.env.get("PREFECT_WORKSPACE");
    const deploymentId = Deno.env.get("PREFECT_PUSH_ATTIO_DEPLOYMENT_ID");

    if (!prefectApiKey || !prefectOrg || !prefectWorkspace || !deploymentId) {
      throw new Error(
        "Missing required environment variables: PREFECT_API_KEY, PREFECT_ORG, PREFECT_WORKSPACE, PREFECT_PUSH_ATTIO_DEPLOYMENT_ID",
      );
    }

    const endpoint =
      `${buildPrefectApiUrl(prefectOrg, prefectWorkspace)}/deployments/${deploymentId}/create_flow_run`;

    console.log(`[push-to-attio] Triggering Prefect deployment: ${deploymentId}`);

    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${prefectApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        parameters: { domains, workspace },
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(
        `Prefect API error: ${response.status} ${errorText}`,
      );
    }

    const result = await response.json();

    console.log(
      `[push-to-attio] Flow run triggered: name=${result.name} id=${result.id}`,
    );

    return jsonResponse({
      success: true,
      flow_run_name: result.name,
      flow_run_url: buildFlowRunUrl(prefectOrg, prefectWorkspace, result.id),
    });
  } catch (error) {
    console.error("[push-to-attio] Unhandled error:", error);
    return jsonResponse({ success: false, error: error.message }, 500);
  }
});
