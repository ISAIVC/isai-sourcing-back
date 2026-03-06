-- Enable pg_trgm extension for trigram-based fuzzy string matching
CREATE EXTENSION IF NOT EXISTS pg_trgm;

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

-- Returns companies that have never been scraped or whose last scrape is on or before ref_date
CREATE OR REPLACE FUNCTION public.get_companies_that_should_be_scraped(ref_date date, row_limit integer)
RETURNS TABLE(domain text, sourcing_date timestamp with time zone)
LANGUAGE sql AS $$
  SELECT
    c.domain,
    wse.sourcing_date
  FROM public.companies c
  LEFT JOIN LATERAL (
    SELECT *
    FROM public.web_scraping_enrichment w
    WHERE w.domain = c.domain
    ORDER BY w.sourcing_date DESC NULLS LAST
    LIMIT 1
  ) wse ON true
  WHERE wse.sourcing_date IS NULL OR wse.sourcing_date <= ref_date
  ORDER BY RANDOM()
  LIMIT row_limit
$$;

-- Returns companies that have never been Dealroom-enriched or whose last enrichment is on or before ref_date
CREATE OR REPLACE FUNCTION public.get_companies_that_should_be_dealroom_enriched(ref_date date, row_limit integer)
RETURNS TABLE(domain text, sourcing_date timestamp with time zone)
LANGUAGE sql AS $$
  SELECT
    c.domain,
    dr.sourcing_date
  FROM public.companies c
  LEFT JOIN LATERAL (
    SELECT *
    FROM public.dealroom_enrichment d
    WHERE d.domain = c.domain
    ORDER BY d.sourcing_date DESC NULLS LAST
    LIMIT 1
  ) dr ON true
  WHERE dr.sourcing_date IS NULL OR dr.sourcing_date <= ref_date
  ORDER BY RANDOM()
  LIMIT row_limit
$$;

-- Returns all distinct non-null values for a given column of sourcing_view.
-- Handles both scalar columns (returns distinct cast-to-text values) and
-- array columns (unnests and returns distinct element values).
-- SECURITY DEFINER so callers need only EXECUTE privilege, not direct table access.
CREATE OR REPLACE FUNCTION public.get_distinct_values(col_name text)
RETURNS text[]
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  col_type text;
  result text[];
BEGIN
  SELECT udt_name INTO col_type
  FROM information_schema.columns
  WHERE table_name = 'sourcing_view' AND column_name = col_name;

  IF col_type = '_text' THEN
    EXECUTE format(
      'SELECT COALESCE(ARRAY(SELECT DISTINCT u FROM sourcing_view, LATERAL unnest(%I) AS u WHERE u IS NOT NULL ORDER BY u), ARRAY[]::text[])',
      col_name
    ) INTO result;
  ELSE
    EXECUTE format(
      'SELECT COALESCE(ARRAY(SELECT DISTINCT %I::text FROM sourcing_view WHERE %I IS NOT NULL ORDER BY %I::text), ARRAY[]::text[])',
      col_name, col_name, col_name
    ) INTO result;
  END IF;

  RETURN COALESCE(result, ARRAY[]::text[]);
END;
$$;
