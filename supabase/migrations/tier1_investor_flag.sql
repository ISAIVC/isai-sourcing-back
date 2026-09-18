-- ---------------------------------------------------------------------------
-- Tier-1 investor flag.
--
-- Two computed columns, derived from bcv.all_investors matched
-- case/whitespace-insensitively against vc_funds where tier = 1:
--   tier_1_investor          boolean  -- true if any tier-1 fund invested
--   tier_1_investors_matched text[]   -- which tier-1 fund(s), for display
--
-- sourcing_mv is a MATERIALIZED view (not a plain view), so adding columns
-- means dropping and recreating it. Everything below runs in one
-- transaction so the app is never left without sourcing_mv.
--
-- search_companies (LANGUAGE sql) hard-depends on sourcing_mv at the
-- Postgres object level (SQL-language function bodies are dependency-
-- tracked, unlike plpgsql), so it must be dropped first and recreated
-- after — with the two new columns added too, for consistency across
-- search modes.
--
-- The 5 existing mv-dirty triggers live on the SOURCE tables (companies,
-- business_computed_values, web_scraping_enrichment, dealroom_enrichment,
-- company_embeddings), not on sourcing_mv itself, so dropping/recreating
-- the mv does not touch them. This migration adds a 6th: vc_funds, so a
-- change to the tier list also marks sourcing_mv dirty for the next
-- refresh (it's a rare edit, so a same-minute refresh is enough).
--
-- IMPORTANT — do not run this from the Supabase SQL Editor / MCP tool:
-- rebuilding sourcing_mv alone measured ~4min (92k rows, incl. the
-- embeddings column), and the HNSW index rebuild adds more on top. Both
-- the SQL Editor's statement_timeout (2min) and the MCP tool's own HTTP
-- proxy (~60-100s) cut the connection well before that, which forces an
-- implicit ROLLBACK (confirmed safe — no partial state left behind) but
-- never lets the migration land. Run this via a direct psql connection
-- instead (see repo CLAUDE.md), with an extended statement_timeout, e.g.:
--   psql "$DATABASE_URL" -c "SET statement_timeout = '20min';" -f supabase/migrations/tier1_investor_flag.sql
--
-- Idempotent: safe to run multiple times.
-- ---------------------------------------------------------------------------

BEGIN;

-- Step 1: drop the function that hard-depends on sourcing_mv
DROP FUNCTION IF EXISTS public.search_companies(text, double precision, integer);

-- Step 2: drop and rebuild the materialized view with the two new columns
DROP MATERIALIZED VIEW IF EXISTS public.sourcing_mv;

CREATE MATERIALIZED VIEW public.sourcing_mv AS
SELECT
  -- Fund scope
  bcv.scope AS fund_prime_scope,

  -- Company basics
  c.logo,
  c.name,
  c.domain AS website,
  c.hq_country,
  c.hq_city,
  c.inc_date,

  -- Web scraping (latest entry per domain)
  wse.description,
  wse.detailed_solution,
  wse.use_cases,
  wse.key_clients AS clients_served,
  wse.nb_of_clients_identified AS number_of_clients_identified,

  -- Business computed - clients/partners
  bcv.global_2000_clients,
  bcv.platforms_cg AS cg_key_platforms,
  bcv.platforms_by AS by_key_platforms,
  bcv.competitors_cg,
  bcv.competitors_by,
  bcv.affiliates_cg,
  bcv.affiliates_by,

  -- GTM
  bcv.gtm_target AS gtm_target_cg,
  bcv.gtm_target_by,

  -- Funding
  bcv.vc_current_stage,
  bcv.first_vc_round_date,
  bcv.first_vc_round_amount,
  c.total_amount_raised,
  bcv.last_vc_round_amount AS last_funding_amount,
  bcv.last_vc_round_date AS last_funding_date,
  bcv.all_investors,
  bcv.last_round_lead_investors,
  bcv.total_number_of_funding_rounds AS total_nber_of_rounds,

  -- Tier-1 investor flag (case/whitespace-insensitive match against vc_funds)
  EXISTS (
    SELECT 1 FROM public.vc_funds vf
    WHERE vf.tier = 1
      AND EXISTS (
        SELECT 1 FROM unnest(bcv.all_investors) inv
        WHERE lower(trim(inv)) = lower(trim(vf.name))
      )
  ) AS tier_1_investor,
  COALESCE((
    SELECT array_agg(DISTINCT vf.name ORDER BY vf.name)
    FROM public.vc_funds vf
    WHERE vf.tier = 1
      AND EXISTS (
        SELECT 1 FROM unnest(bcv.all_investors) inv
        WHERE lower(trim(inv)) = lower(trim(vf.name))
      )
  ), ARRAY[]::text[]) AS tier_1_investors_matched,

  -- Business
  bcv.business_model,
  bcv.founders_background,
  bcv.serial_entrepreneur,

  -- Sectors/industries
  bcv.primary_sector_served_cg,
  bcv.primary_industry_served_cg,
  bcv.primary_sector_served_by,
  bcv.primary_industry_served_by,
  bcv.all_industries_served_sorted AS all_industries_served,
  bcv.business_mapping,
  bcv.tech_tags_dynamic AS tech_tags,

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
  bcv.in_attio AS present_in_attio,
  bcv.attio_stage AS last_stage_in_attio,
  bcv.attio_status AS last_status_in_attio,

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

-- Permissions on sourcing_mv (lost on drop, must be redone)
GRANT SELECT ON public.sourcing_mv TO authenticated;
REVOKE ALL ON public.sourcing_mv FROM anon;

-- Indexes (lost on drop, must be redone)
CREATE UNIQUE INDEX ON public.sourcing_mv (website);
CREATE INDEX ON public.sourcing_mv USING hnsw (full_embedding vector_cosine_ops);

-- Step 3: recreate search_companies with the two new columns
CREATE OR REPLACE FUNCTION public.search_companies(
  search_query text,
  similarity_threshold double precision DEFAULT 0.10,
  row_limit integer DEFAULT 50
)
RETURNS TABLE(
  fund_prime_scope text,
  logo text,
  name text,
  website text,
  hq_country text[],
  hq_city text,
  inc_date integer,
  description text,
  detailed_solution text,
  use_cases text,
  clients_served text[],
  number_of_clients_identified bigint,
  global_2000_clients text[],
  cg_key_platforms text[],
  by_key_platforms text[],
  competitors_cg text[],
  competitors_by text[],
  affiliates_cg text[],
  affiliates_by text[],
  gtm_target_cg text,
  gtm_target_by text,
  vc_current_stage text,
  first_vc_round_date date,
  first_vc_round_amount numeric,
  total_amount_raised numeric,
  last_funding_amount numeric,
  last_funding_date date,
  all_investors text[],
  last_round_lead_investors text[],
  total_nber_of_rounds integer,
  tier_1_investor boolean,
  tier_1_investors_matched text[],
  business_model text,
  founders_background text,
  serial_entrepreneur boolean,
  primary_sector_served_cg text,
  primary_industry_served_cg text,
  primary_sector_served_by text,
  primary_industry_served_by text,
  all_industries_served text[],
  business_mapping text,
  tech_tags text[],
  solution_fit_cg integer,
  solution_fit_by integer,
  business_fit_cg integer,
  business_fit_by integer,
  maturity_fit integer,
  equity_score integer,
  traction_score integer,
  global_fund_score integer,
  present_in_attio boolean,
  last_stage_in_attio text,
  last_status_in_attio text,
  headcount integer,
  headcount_growth_l12m numeric,
  web_traffic integer,
  web_traffic_growth_l12m numeric
)
LANGUAGE sql STABLE AS $$
  SELECT
    mv.fund_prime_scope, mv.logo, mv.name, mv.website, mv.hq_country, mv.hq_city,
    mv.inc_date, mv.description, mv.detailed_solution, mv.use_cases,
    mv.clients_served, mv.number_of_clients_identified, mv.global_2000_clients,
    mv.cg_key_platforms, mv.by_key_platforms, mv.competitors_cg, mv.competitors_by,
    mv.affiliates_cg, mv.affiliates_by, mv.gtm_target_cg, mv.gtm_target_by,
    mv.vc_current_stage, mv.first_vc_round_date, mv.first_vc_round_amount,
    mv.total_amount_raised, mv.last_funding_amount, mv.last_funding_date,
    mv.all_investors, mv.last_round_lead_investors, mv.total_nber_of_rounds,
    mv.tier_1_investor, mv.tier_1_investors_matched,
    mv.business_model, mv.founders_background, mv.serial_entrepreneur,
    mv.primary_sector_served_cg, mv.primary_industry_served_cg,
    mv.primary_sector_served_by, mv.primary_industry_served_by,
    mv.all_industries_served, mv.business_mapping, mv.tech_tags,
    mv.solution_fit_cg, mv.solution_fit_by, mv.business_fit_cg, mv.business_fit_by,
    mv.maturity_fit, mv.equity_score, mv.traction_score, mv.global_fund_score,
    mv.present_in_attio, mv.last_stage_in_attio, mv.last_status_in_attio,
    mv.headcount, mv.headcount_growth_l12m, mv.web_traffic, mv.web_traffic_growth_l12m
  FROM   public.sourcing_mv  mv
  WHERE
    similarity(search_query, mv.name)    > similarity_threshold
    OR similarity(search_query, mv.website) > similarity_threshold
    OR mv.name    ILIKE '%' || search_query || '%'
    OR mv.website ILIKE '%' || search_query || '%'
  ORDER BY
    GREATEST(
      similarity(search_query, mv.name),
      similarity(search_query, mv.website)
    ) DESC
  LIMIT row_limit;
$$;

GRANT EXECUTE ON FUNCTION public.search_companies(TEXT, FLOAT, INT) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.search_companies(TEXT, FLOAT, INT) FROM anon;

-- Step 4: same two columns on sourcing_view (plain view — additive, no drop).
-- get_distinct_values() reads sourcing_view to populate filter dropdowns, so
-- the multitag filter on tier_1_investors_matched needs it there too.
CREATE OR REPLACE VIEW public.sourcing_view
  WITH (security_invoker = true)
AS
SELECT
  bcv.scope AS fund_prime_scope,
  c.logo,
  c.name,
  c.domain AS website,
  c.hq_country,
  c.hq_city,
  c.inc_date,
  wse.description,
  wse.detailed_solution,
  wse.use_cases,
  wse.key_clients AS clients_served,
  wse.nb_of_clients_identified AS number_of_clients_identified,
  bcv.global_2000_clients,
  bcv.platforms_cg AS cg_key_platforms,
  bcv.platforms_by AS by_key_platforms,
  bcv.competitors_cg,
  bcv.competitors_by,
  bcv.affiliates_cg,
  bcv.affiliates_by,
  bcv.gtm_target AS gtm_target_cg,
  bcv.gtm_target_by,
  bcv.vc_current_stage,
  bcv.first_vc_round_date,
  bcv.first_vc_round_amount,
  c.total_amount_raised,
  bcv.last_vc_round_amount AS last_funding_amount,
  bcv.last_vc_round_date AS last_funding_date,
  bcv.all_investors,
  bcv.last_round_lead_investors,
  bcv.total_number_of_funding_rounds AS total_nber_of_rounds,
  EXISTS (
    SELECT 1 FROM public.vc_funds vf
    WHERE vf.tier = 1
      AND EXISTS (
        SELECT 1 FROM unnest(bcv.all_investors) inv
        WHERE lower(trim(inv)) = lower(trim(vf.name))
      )
  ) AS tier_1_investor,
  COALESCE((
    SELECT array_agg(DISTINCT vf.name ORDER BY vf.name)
    FROM public.vc_funds vf
    WHERE vf.tier = 1
      AND EXISTS (
        SELECT 1 FROM unnest(bcv.all_investors) inv
        WHERE lower(trim(inv)) = lower(trim(vf.name))
      )
  ), ARRAY[]::text[]) AS tier_1_investors_matched,
  bcv.business_model,
  bcv.founders_background,
  bcv.serial_entrepreneur,
  bcv.primary_sector_served_cg,
  bcv.primary_industry_served_cg,
  bcv.primary_sector_served_by,
  bcv.primary_industry_served_by,
  bcv.all_industries_served_sorted AS all_industries_served,
  bcv.business_mapping,
  bcv.tech_tags_dynamic AS tech_tags,
  COALESCE(c.solution_fit_cg_manual, bcv.solution_fit_cg) AS solution_fit_cg,
  COALESCE(c.solution_fit_by_manual, bcv.solution_fit_by) AS solution_fit_by,
  COALESCE(c.business_fit_cg_manual, bcv.business_fit_cg) AS business_fit_cg,
  COALESCE(c.business_fit_by_manual, bcv.business_fit_by) AS business_fit_by,
  COALESCE(c.maturity_fit_manual, bcv.maturity_fit) AS maturity_fit,
  COALESCE(c.equity_score_manual, bcv.equity_score) AS equity_score,
  COALESCE(c.traction_score_manual, bcv.traction_score) AS traction_score,
  COALESCE(c.global_fund_score_manual, bcv.global_fund_score) AS global_fund_score,
  bcv.in_attio AS present_in_attio,
  bcv.attio_stage AS last_stage_in_attio,
  bcv.attio_status AS last_status_in_attio,
  dre.headcount,
  dre.headcount_growth_l12m,
  dre.web_traffic,
  dre.web_traffic_growth_l12m
FROM public.companies c
LEFT JOIN public.business_computed_values bcv ON bcv.domain = c.domain
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
) dre ON true;

GRANT SELECT ON public.sourcing_view TO authenticated;

-- Step 5: mark sourcing_mv dirty when the tier-1 fund list changes too
-- (the 5 existing dirty-triggers on companies/bcv/wse/dre/embeddings are
-- untouched by this migration; this adds vc_funds as a 6th source).
DROP TRIGGER IF EXISTS trg_vc_funds_dirty_mv ON public.vc_funds;
CREATE TRIGGER trg_vc_funds_dirty_mv
  AFTER INSERT OR UPDATE OR DELETE ON public.vc_funds
  FOR EACH STATEMENT EXECUTE FUNCTION public.mark_sourcing_mv_dirty();

-- Step 6: one-click toolbar preset ("filter" kind: filters + sort only).
-- col/op/dir field names must match utils/queryFilters.js exactly.
INSERT INTO public.table_presets (id, kind, name, sort_order, config)
VALUES (
  'cccccccc-0000-4000-8000-000000000003',
  'filter',
  'Tier 1 backed',
  3,
  '{"filterConfig":[{"col":"tier_1_investor","op":"is","value":true}],"sortConfig":[{"col":"tier_1_investor","dir":"desc"}]}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

COMMIT;
