-- ---------------------------------------------------------------------------
-- Semantic competitor search: "find the companies that do the same thing".
--
-- Uses company_embeddings.solution_and_use_cases_embedding (detailed_solution +
-- use_cases, embedded with task type CLASSIFICATION) rather than full_embedding
-- (which also carries the marketing description, and pulls in companies that
-- *talk* alike rather than companies that *do* the same thing).
--
-- The source vector is read straight from the table: no embedding API call, so
-- the whole thing is a single indexed ANN query.
--
-- Returns the same column set as match_companies_filtered (plus similarity), so
-- the results can be dropped into the main table view like semantic results.
-- Idempotent.
-- ---------------------------------------------------------------------------

-- HNSW index on the solution/use-cases axis (full_embedding already has one on
-- sourcing_mv). Cosine, to match the <=> operator used below.
CREATE INDEX IF NOT EXISTS company_embeddings_solution_hnsw
  ON public.company_embeddings
  USING hnsw (solution_and_use_cases_embedding extensions.vector_cosine_ops);

-- p_domain          : companies.domain (= sourcing_mv.website)
-- p_limit           : rows returned after the similarity floor
-- p_min_similarity  : cosine floor, 0..1. Calibrate on a few known companies:
--                     without it the ANN always returns p_limit rows, competitors
--                     or not.
DROP FUNCTION IF EXISTS public.match_competitors(text, int, float8);

CREATE OR REPLACE FUNCTION public.match_competitors(
  p_domain         text,
  p_limit          int      DEFAULT 40,
  p_min_similarity float8   DEFAULT 0.5
)
RETURNS TABLE (
  fund_prime_scope              text,
  logo                          text,
  name                          text,
  website                       text,
  hq_country                    text[],
  hq_city                       text,
  inc_date                      integer,
  description                   text,
  detailed_solution             text,
  use_cases                     text,
  clients_served                text[],
  number_of_clients_identified  bigint,
  global_2000_clients           text[],
  cg_key_platforms              text[],
  by_key_platforms              text[],
  competitors_cg                text[],
  competitors_by                text[],
  affiliates_cg                 text[],
  affiliates_by                 text[],
  gtm_target_cg                 text,
  gtm_target_by                 text,
  vc_current_stage              text,
  first_vc_round_date           date,
  first_vc_round_amount         numeric,
  total_amount_raised           numeric,
  last_funding_amount           numeric,
  last_funding_date             date,
  all_investors                 text[],
  last_round_lead_investors     text[],
  total_nber_of_rounds          integer,
  business_model                text,
  founders_background           text,
  serial_entrepreneur           boolean,
  primary_sector_served_cg      text,
  primary_industry_served_cg    text,
  primary_sector_served_by      text,
  primary_industry_served_by    text,
  all_industries_served         text[],
  business_mapping              text,
  tech_tags                     text[],
  solution_fit_cg               integer,
  solution_fit_by               integer,
  business_fit_cg               integer,
  business_fit_by               integer,
  maturity_fit                  integer,
  equity_score                  integer,
  traction_score                integer,
  global_fund_score             integer,
  present_in_attio              boolean,
  last_stage_in_attio           text,
  last_status_in_attio          text,
  headcount                     integer,
  headcount_growth_l12m         numeric,
  web_traffic                   integer,
  web_traffic_growth_l12m       numeric,
  similarity                    float8
)
LANGUAGE plpgsql
STABLE
-- SECURITY DEFINER: company_embeddings has RLS enabled with no permissive
-- policy, so authenticated users can only reach the vectors through this
-- function.
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_embedding extensions.vector(768);
BEGIN
  SELECT ce.solution_and_use_cases_embedding
    INTO v_embedding
    FROM public.company_embeddings ce
   WHERE ce.domain = p_domain;

  -- Unknown domain, or a company the pipeline has not embedded yet.
  IF v_embedding IS NULL THEN
    RETURN;
  END IF;

  -- An HNSW scan only walks hnsw.ef_search candidates (default 40), so the
  -- over-fetch below would be silently capped at 40 rows. Raise it to match,
  -- transaction-locally (third argument = is_local).
  PERFORM set_config('hnsw.ef_search', GREATEST(p_limit * 5, 200)::text, true);

  RETURN QUERY
  WITH neighbours AS (
    -- Over-fetch: the similarity floor and the join to sourcing_mv both drop
    -- rows, and the LIMIT is what lets the planner use the HNSW index.
    SELECT ce.domain,
           1 - (ce.solution_and_use_cases_embedding <=> v_embedding) AS similarity
      FROM public.company_embeddings ce
     WHERE ce.solution_and_use_cases_embedding IS NOT NULL
       AND ce.domain <> p_domain
     ORDER BY ce.solution_and_use_cases_embedding <=> v_embedding
     LIMIT GREATEST(p_limit * 5, 200)
  )
  SELECT sv.fund_prime_scope, sv.logo, sv.name, sv.website, sv.hq_country, sv.hq_city,
         sv.inc_date, sv.description, sv.detailed_solution, sv.use_cases,
         sv.clients_served, sv.number_of_clients_identified, sv.global_2000_clients,
         sv.cg_key_platforms, sv.by_key_platforms, sv.competitors_cg, sv.competitors_by,
         sv.affiliates_cg, sv.affiliates_by, sv.gtm_target_cg, sv.gtm_target_by,
         sv.vc_current_stage, sv.first_vc_round_date, sv.first_vc_round_amount,
         sv.total_amount_raised, sv.last_funding_amount, sv.last_funding_date,
         sv.all_investors, sv.last_round_lead_investors, sv.total_nber_of_rounds,
         sv.business_model, sv.founders_background, sv.serial_entrepreneur,
         sv.primary_sector_served_cg, sv.primary_industry_served_cg,
         sv.primary_sector_served_by, sv.primary_industry_served_by,
         sv.all_industries_served, sv.business_mapping, sv.tech_tags,
         sv.solution_fit_cg, sv.solution_fit_by, sv.business_fit_cg, sv.business_fit_by,
         sv.maturity_fit, sv.equity_score, sv.traction_score, sv.global_fund_score,
         sv.present_in_attio, sv.last_stage_in_attio, sv.last_status_in_attio,
         sv.headcount, sv.headcount_growth_l12m, sv.web_traffic, sv.web_traffic_growth_l12m,
         n.similarity
    FROM neighbours n
    JOIN public.sourcing_mv sv ON sv.website = n.domain
   WHERE n.similarity >= p_min_similarity
   ORDER BY n.similarity DESC
   LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.match_competitors(text, int, float8) FROM anon;
GRANT EXECUTE ON FUNCTION public.match_competitors(text, int, float8) TO authenticated;
