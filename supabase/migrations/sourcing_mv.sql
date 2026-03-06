-- Step A: single-row dirty-flag table
CREATE TABLE IF NOT EXISTS public.mv_refresh_state (
  id              bool PRIMARY KEY DEFAULT true CHECK (id),
  needs_refresh   bool NOT NULL DEFAULT true,
  last_refreshed_at timestamptz
);
INSERT INTO public.mv_refresh_state (id, needs_refresh)
VALUES (true, true)
ON CONFLICT DO NOTHING;

-- Step B: materialized view — inlined join logic (no dependency on sourcing_view)
CREATE MATERIALIZED VIEW public.sourcing_mv AS
SELECT
  -- Fund scope
  bcv.scope                                                     AS fund_prime_scope,

  -- Company basics
  c.logo,
  c.name,
  c.domain                                                      AS website,
  c.hq_country,
  c.hq_city,
  c.inc_date,

  -- Web scraping (latest entry per domain)
  wse.description,
  wse.detailed_solution,
  wse.use_cases,
  wse.key_clients                                               AS clients_served,
  wse.nb_of_clients_identified                                  AS number_of_clients_identified,

  -- Business computed — clients / partners
  bcv.global_2000_clients,
  bcv.platforms_cg                                              AS cg_key_platforms,
  bcv.platforms_by                                              AS by_key_platforms,
  bcv.competitors_cg,
  bcv.competitors_by,
  bcv.affiliates_cg,
  bcv.affiliates_by,

  -- GTM
  bcv.gtm_target                                                AS gtm_target_cg,
  bcv.gtm_target_by,

  -- Funding
  bcv.vc_current_stage,
  bcv.first_vc_round_date,
  bcv.first_vc_round_amount,
  c.total_amount_raised,
  bcv.last_vc_round_amount                                      AS last_funding_amount,
  bcv.last_vc_round_date                                        AS last_funding_date,
  bcv.all_investors,
  bcv.last_round_lead_investors,
  bcv.total_number_of_funding_rounds                            AS total_nber_of_rounds,

  -- Business
  bcv.business_model,
  bcv.founders_background,
  bcv.serial_entrepreneur,

  -- Sectors / industries
  bcv.primary_sector_served_cg,
  bcv.primary_industry_served_cg,
  bcv.primary_sector_served_by,
  bcv.primary_industry_served_by,
  bcv.all_industries_served_sorted                              AS all_industries_served,
  bcv.business_mapping,
  bcv.tech_tags_dynamic                                         AS tech_tags,

  -- Scores (manual overrides from companies table take precedence)
  COALESCE(c.solution_fit_cg_manual,    bcv.solution_fit_cg)   AS solution_fit_cg,
  COALESCE(c.solution_fit_by_manual,    bcv.solution_fit_by)   AS solution_fit_by,
  COALESCE(c.business_fit_cg_manual,    bcv.business_fit_cg)   AS business_fit_cg,
  COALESCE(c.business_fit_by_manual,    bcv.business_fit_by)   AS business_fit_by,
  COALESCE(c.maturity_fit_manual,       bcv.maturity_fit)      AS maturity_fit,
  COALESCE(c.equity_score_manual,       bcv.equity_score)      AS equity_score,
  COALESCE(c.traction_score_manual,     bcv.traction_score)    AS traction_score,
  COALESCE(c.global_fund_score_manual,  bcv.global_fund_score) AS global_fund_score,

  -- Attio
  bcv.in_attio                                                  AS present_in_attio,
  bcv.attio_stage                                               AS last_stage_in_attio,
  bcv.attio_status                                              AS last_status_in_attio,

  -- Dealroom enrichment (latest entry per domain)
  dre.headcount,
  dre.headcount_growth_l12m,
  dre.web_traffic,
  dre.web_traffic_growth_l12m,

  -- Embedding (nullable — companies without embeddings still appear)
  ce.full_embedding

FROM public.companies c
LEFT JOIN public.business_computed_values bcv
  ON bcv.domain = c.domain
LEFT JOIN LATERAL (
  SELECT *
  FROM public.web_scraping_enrichment w
  WHERE w.domain = c.domain
  ORDER BY w.sourcing_date DESC NULLS LAST
  LIMIT 1
) wse ON true
LEFT JOIN LATERAL (
  SELECT *
  FROM public.dealroom_enrichment d
  WHERE d.domain = c.domain
  ORDER BY d.sourcing_date DESC NULLS LAST
  LIMIT 1
) dre ON true
LEFT JOIN public.company_embeddings ce
  ON ce.domain = c.domain;

-- Permissions on sourcing_mv
GRANT SELECT ON public.sourcing_mv TO authenticated;
REVOKE ALL ON public.sourcing_mv FROM anon;

-- Permissions on mv_refresh_state (service role only — no direct user access needed)
REVOKE ALL ON public.mv_refresh_state FROM anon;
REVOKE ALL ON public.mv_refresh_state FROM authenticated;

-- RLS on mv_refresh_state: enabled with no permissive policy → blocks all
-- direct access from anon/authenticated; SECURITY DEFINER functions bypass RLS.
ALTER TABLE public.mv_refresh_state ENABLE ROW LEVEL SECURITY;

-- Step C: indexes
-- Required for REFRESH CONCURRENTLY (no exclusive table lock)
CREATE UNIQUE INDEX ON public.sourcing_mv (website);

-- HNSW index for fast cosine-distance vector search
CREATE INDEX ON public.sourcing_mv
  USING hnsw (full_embedding vector_cosine_ops);

-- Step D: trigger function that marks the MV dirty
CREATE OR REPLACE FUNCTION public.mark_sourcing_mv_dirty()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE public.mv_refresh_state SET needs_refresh = true WHERE id = true;
  RETURN NULL;
END;
$$;

-- Step E: statement-level triggers on all 5 source tables
CREATE TRIGGER trg_companies_dirty_mv
  AFTER INSERT OR UPDATE OR DELETE ON public.companies
  FOR EACH STATEMENT EXECUTE FUNCTION public.mark_sourcing_mv_dirty();

CREATE TRIGGER trg_bcv_dirty_mv
  AFTER INSERT OR UPDATE OR DELETE ON public.business_computed_values
  FOR EACH STATEMENT EXECUTE FUNCTION public.mark_sourcing_mv_dirty();

CREATE TRIGGER trg_wse_dirty_mv
  AFTER INSERT OR UPDATE OR DELETE ON public.web_scraping_enrichment
  FOR EACH STATEMENT EXECUTE FUNCTION public.mark_sourcing_mv_dirty();

CREATE TRIGGER trg_dre_dirty_mv
  AFTER INSERT OR UPDATE OR DELETE ON public.dealroom_enrichment
  FOR EACH STATEMENT EXECUTE FUNCTION public.mark_sourcing_mv_dirty();

CREATE TRIGGER trg_embeddings_dirty_mv
  AFTER INSERT OR UPDATE OR DELETE ON public.company_embeddings
  FOR EACH STATEMENT EXECUTE FUNCTION public.mark_sourcing_mv_dirty();

-- Step F: conditional refresh function (called by pg_cron)
CREATE OR REPLACE FUNCTION public.refresh_sourcing_mv_if_dirty()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.mv_refresh_state WHERE needs_refresh = true) THEN
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.sourcing_mv;
    UPDATE public.mv_refresh_state
      SET needs_refresh = false, last_refreshed_at = now()
    WHERE id = true;
  END IF;
END;
$$;

-- Step G: pg_cron schedule (every 1 minute)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
  'refresh-sourcing-mv',
  '* * * * *',
  $$SELECT public.refresh_sourcing_mv_if_dirty()$$
);
