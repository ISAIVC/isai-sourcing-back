-- Enable pg_trgm extension for trigram-based fuzzy string matching
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE OR REPLACE FUNCTION public.search_companies(
  search_query         TEXT,
  similarity_threshold FLOAT DEFAULT 0.15,
  max_results          INT   DEFAULT 50
)
RETURNS SETOF public.sourcing_view
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
  SELECT sv.*
  FROM   public.sourcing_view sv
  WHERE
    similarity(search_query, sv.name)    > similarity_threshold
    OR similarity(search_query, sv.website) > similarity_threshold
  ORDER BY
    GREATEST(
      similarity(search_query, sv.name),
      similarity(search_query, sv.website)
    ) DESC
  LIMIT max_results;
$$;

GRANT EXECUTE ON FUNCTION public.search_companies(TEXT, FLOAT, INT) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.search_companies(TEXT, FLOAT, INT) FROM anon;

-- Migration: match_companies RPC for vector similarity search
-- Requires: pgvector extension (enabled in vectorized_tables.sql)
--           company_embeddings table with full_embedding vector(1536)
--           sourcing_view

CREATE OR REPLACE FUNCTION public.match_companies(query_embedding vector(1536))
RETURNS TABLE (
  fund_prime_scope              text,
  logo                          text,
  name                          text,
  website                       text,
  hq_country                    text,
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
    1 - (ce.full_embedding <=> query_embedding) AS similarity
  FROM   public.sourcing_view sv
  JOIN   public.company_embeddings ce ON ce.domain = sv.website
  WHERE  ce.full_embedding IS NOT NULL
$$;

GRANT EXECUTE ON FUNCTION public.match_companies(vector) TO authenticated;
