-- Enable pg_trgm extension for trigram-based fuzzy string matching
CREATE EXTENSION IF NOT EXISTS pg_trgm;

 CREATE OR REPLACE FUNCTION public.search_companies(                                                                                                        
    search_query text,
    similarity_threshold double precision DEFAULT 0.10                                                                                                       
  )                                                                                                                                                          
  RETURNS SETOF sourcing_view                                                                                                                                
  LANGUAGE sql STABLE AS $$                                                                                                                                  
    SELECT sv.*                                                                                                                                              
    FROM   public.sourcing_view sv                                                                                                                           
    WHERE
      similarity(search_query, sv.name)    > similarity_threshold
      OR similarity(search_query, sv.website) > similarity_threshold
      OR sv.name    ILIKE '%' || search_query || '%'
      OR sv.website ILIKE '%' || search_query || '%'
    ORDER BY
      GREATEST(
        similarity(search_query, sv.name),
        similarity(search_query, sv.website)
      ) DESC;
  $$;

GRANT EXECUTE ON FUNCTION public.search_companies(TEXT, FLOAT, INT) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.search_companies(TEXT, FLOAT, INT) FROM anon;

-- Migration: match_companies RPC for vector similarity search
-- Requires: pgvector extension (enabled in vectorized_tables.sql)
--           company_embeddings table with full_embedding vector(768)
--           sourcing_view

CREATE OR REPLACE FUNCTION public.match_companies(query_embedding vector(768))
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
LANGUAGE sql STABLE SECURITY INVOKER
AS $$
  SELECT
    sv.fund_prime_scope,
    sv.logo,
    sv.name,
    sv.website,
    sv.hq_country,
    sv.hq_city,
    sv.inc_date,
    sv.description,
    sv.detailed_solution,
    sv.use_cases,
    sv.clients_served,
    sv.number_of_clients_identified,
    sv.global_2000_clients,
    sv.cg_key_platforms,
    sv.by_key_platforms,
    sv.competitors_cg,
    sv.competitors_by,
    sv.affiliates_cg,
    sv.affiliates_by,
    sv.gtm_target_cg,
    sv.gtm_target_by,
    sv.vc_current_stage,
    sv.first_vc_round_date,
    sv.first_vc_round_amount,
    sv.total_amount_raised,
    sv.last_funding_amount,
    sv.last_funding_date,
    sv.all_investors,
    sv.last_round_lead_investors,
    sv.total_nber_of_rounds,
    sv.business_model,
    sv.founders_background,
    sv.serial_entrepreneur,
    sv.primary_sector_served_cg,
    sv.primary_industry_served_cg,
    sv.primary_sector_served_by,
    sv.primary_industry_served_by,
    sv.all_industries_served,
    sv.business_mapping,
    sv.tech_tags,
    sv.solution_fit_cg,
    sv.solution_fit_by,
    sv.business_fit_cg,
    sv.business_fit_by,
    sv.maturity_fit,
    sv.equity_score,
    sv.traction_score,
    sv.global_fund_score,
    sv.present_in_attio,
    sv.last_stage_in_attio,
    sv.last_status_in_attio,
    sv.headcount,
    sv.headcount_growth_l12m,
    sv.web_traffic,
    sv.web_traffic_growth_l12m,
    1 - (ce.full_embedding <=> query_embedding) AS similarity
  FROM   public.sourcing_view sv
  JOIN   public.company_embeddings ce ON ce.domain = sv.website
  WHERE  ce.full_embedding IS NOT NULL
  ORDER BY ce.full_embedding <=> query_embedding
$$;

GRANT EXECUTE ON FUNCTION public.match_companies(vector) TO authenticated;

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
