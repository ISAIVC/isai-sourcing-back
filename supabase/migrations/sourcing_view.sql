CREATE OR REPLACE VIEW public.sourcing_view
  WITH (security_invoker = true)
AS
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
  COALESCE(c.solution_fit_cg_manual, bcv.solution_fit_cg) AS solution_fit_cg,
  COALESCE(c.solution_fit_by_manual, bcv.solution_fit_by) AS solution_fit_by,
  COALESCE(c.business_fit_cg_manual, bcv.business_fit_cg) AS business_fit_cg,
  COALESCE(c.business_fit_by_manual, bcv.business_fit_by) AS business_fit_by,
  COALESCE(c.maturity_fit_manual, bcv.maturity_fit) AS maturity_fit,
  COALESCE(c.equity_score_manual, bcv.equity_score) AS equity_score,
  COALESCE(c.traction_score_manual, bcv.traction_score) AS traction_score,
  COALESCE(c.global_fund_score_manual, bcv.global_fund_score) AS global_fund_score,

  -- Attio
  bcv.in_attio AS present_in_attio,
  bcv.attio_stage AS last_stage_in_attio,
  bcv.attio_status AS last_status_in_attio,

  -- Dealroom enrichment (latest entry per domain)
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

-- Grant access to authenticated users (matches policy pattern on underlying tables)
GRANT SELECT ON public.sourcing_view TO authenticated;
REVOKE ALL ON public.sourcing_view FROM anon;

-- sourcing_view column descriptions

-- Fund scope
COMMENT ON COLUMN public.sourcing_view.fund_prime_scope IS
  'Fund scope for this company. "CG" for Capgemini only, "BY" for Bouygues only, "BOTH" for both funds. Determined solely by the sectors and industries served. Source: business_computed_values.scope.';

-- Company basics
COMMENT ON COLUMN public.sourcing_view.logo IS
  'URL pointing to the company logo image.';

COMMENT ON COLUMN public.sourcing_view.name IS
  'Official company name.';

COMMENT ON COLUMN public.sourcing_view.website IS
  'Main company domain name.';

COMMENT ON COLUMN public.sourcing_view.hq_country IS
  'Country where the company headquarters is located.';

COMMENT ON COLUMN public.sourcing_view.hq_city IS
  'City where the company headquarters is located.';

COMMENT ON COLUMN public.sourcing_view.inc_date IS
  'Year the company was founded (YYYY format, stored as integer).';

-- Web scraping (latest entry per domain)
COMMENT ON COLUMN public.sourcing_view.description IS
  'General description of the company and what it does, extracted from the most recent website scrape.';

COMMENT ON COLUMN public.sourcing_view.detailed_solution IS
  'Detailed explanation of the company product or solution offering, extracted from the most recent website scrape.';

COMMENT ON COLUMN public.sourcing_view.use_cases IS
  'Target use cases or problem scenarios the company addresses, extracted from the most recent website scrape.';

COMMENT ON COLUMN public.sourcing_view.clients_served IS
  'Notable clients or customers mentioned on the website, extracted from the most recent website scrape.';

COMMENT ON COLUMN public.sourcing_view.number_of_clients_identified IS
  'Number of clients identified or claimed on the website, extracted from the most recent website scrape.';

-- Business computed - clients/partners
COMMENT ON COLUMN public.sourcing_view.global_2000_clients IS
  'List of Forbes Global 2000 companies identified as clients of this company. Matched using fuzzy matching against the global_2000 reference table.';

COMMENT ON COLUMN public.sourcing_view.cg_key_platforms IS
  'List of Capgemini platforms that are partners or clients of this company. Matched using fuzzy matching against the cap_sw_partners reference table.';

COMMENT ON COLUMN public.sourcing_view.by_key_platforms IS
  'List of Bouygues platforms that are partners or clients of this company. Matched using fuzzy matching against the by_platforms reference table.';

COMMENT ON COLUMN public.sourcing_view.competitors_cg IS
  'List of Capgemini competitors that are partners or clients of this company. Matched using fuzzy matching against the cap_competitors reference table.';

COMMENT ON COLUMN public.sourcing_view.competitors_by IS
  'List of Bouygues competitors that are partners or clients of this company. Matched using fuzzy matching against the by_competitors reference table.';

COMMENT ON COLUMN public.sourcing_view.affiliates_cg IS
  'List of Capgemini affiliates that are partners or clients of this company. Matched using fuzzy matching against the cap_affiliates reference table.';

COMMENT ON COLUMN public.sourcing_view.affiliates_by IS
  'List of Bouygues affiliates that are partners or clients of this company. Matched using fuzzy matching against the by_affiliates reference table.';

-- GTM
COMMENT ON COLUMN public.sourcing_view.gtm_target_cg IS
  'Go-to-market target classification for the Capgemini fund perspective.';

COMMENT ON COLUMN public.sourcing_view.gtm_target_by IS
  'Go-to-market target classification for the Bouygues fund perspective.';

-- Funding
COMMENT ON COLUMN public.sourcing_view.vc_current_stage IS
  'Current venture capital stage of the company (e.g. Seed, Series A, Series B…).';

COMMENT ON COLUMN public.sourcing_view.first_vc_round_date IS
  'Date of the first institutional VC round';

COMMENT ON COLUMN public.sourcing_view.first_vc_round_amount IS
  'Amount raised in the first institutional VC round in USD';

COMMENT ON COLUMN public.sourcing_view.total_amount_raised IS
  'Total cumulative funding raised by the company, in USD.';

COMMENT ON COLUMN public.sourcing_view.last_funding_amount IS
  'Amount raised in the most recent institutional VC round in USD';

COMMENT ON COLUMN public.sourcing_view.last_funding_date IS
  'Date of the most recent institutional VC round';

COMMENT ON COLUMN public.sourcing_view.all_investors IS
  'All investors of the company, aggregated from the funding_rounds table';

COMMENT ON COLUMN public.sourcing_view.last_round_lead_investors IS
  'Lead investor(s) of the most recent funding round';

COMMENT ON COLUMN public.sourcing_view.total_nber_of_rounds IS
  'Total number of funding rounds';

-- Business
COMMENT ON COLUMN public.sourcing_view.business_model IS
  'Business model classification for the company. Classified by LLM using the business_models reference taxonomy.';

COMMENT ON COLUMN public.sourcing_view.founders_background IS
  'Summary of the founders professional background';

COMMENT ON COLUMN public.sourcing_view.serial_entrepreneur IS
  'Whether any founder of the company is a serial entrepreneur (has founded multiple companies)';

-- Sectors/industries
COMMENT ON COLUMN public.sourcing_view.primary_sector_served_cg IS
  'Primary sector the company serves, classified using the taxonomy';

COMMENT ON COLUMN public.sourcing_view.primary_industry_served_cg IS
  'Primary industry the company serves, classified using the taxonomy';

COMMENT ON COLUMN public.sourcing_view.primary_sector_served_by IS
  'Primary sector the company serves, classified using the taxonomy';

COMMENT ON COLUMN public.sourcing_view.primary_industry_served_by IS
  'Primary industry the company serves, classified using the taxonomy';

COMMENT ON COLUMN public.sourcing_view.all_industries_served IS
  'Complete list of all industries the company serves, sorted by relevance.';

COMMENT ON COLUMN public.sourcing_view.business_mapping IS
  'Business mapping classification for the company. ';

COMMENT ON COLUMN public.sourcing_view.tech_tags IS
  'Dynamically computed technology tags, generated by the pipeline based on company data analysis.';

-- Scores (manual overrides from companies table take precedence)
COMMENT ON COLUMN public.sourcing_view.solution_fit_cg IS
  'Solution fit score for the Capgemini fund. Integer score evaluating how well the company solution fits Capgemini needs. 1 = perfect fit, 4 = worst fit';

COMMENT ON COLUMN public.sourcing_view.solution_fit_by IS
  'Solution fit score for the Bouygues fund. Integer score evaluating how well the company solution fits Bouygues needs. 1 = perfect fit, 4 = worst fit';

COMMENT ON COLUMN public.sourcing_view.business_fit_cg IS
  'Business fit score for the Capgemini fund. Integer score evaluating business compatibility with Capgemini. 1 = perfect fit, 4 = worst fit';

COMMENT ON COLUMN public.sourcing_view.business_fit_by IS
  'Business fit score for the Bouygues fund. Integer score evaluating business compatibility with Bouygues. 1 = perfect fit, 4 = worst fit';

COMMENT ON COLUMN public.sourcing_view.maturity_fit IS
  'Maturity fit score. Fund-agnostic integer score evaluating the company maturity level for investment readiness. 1 = perfect fit, 4 = worst fit';

COMMENT ON COLUMN public.sourcing_view.equity_score IS
  'Equity score. Integer score evaluating the investment attractiveness from an equity perspective. 1 = perfect fit, 4 = worst fit';

COMMENT ON COLUMN public.sourcing_view.traction_score IS
  'Traction score. Integer score evaluating the company growth and market traction. 1 = perfect fit, 4 = worst fit';

COMMENT ON COLUMN public.sourcing_view.global_fund_score IS
  'Global fund fit score. Overall integer score combining all fit dimensions for fund-level decision making. 1 = perfect fit, 4 = worst fit';

-- Attio
COMMENT ON COLUMN public.sourcing_view.present_in_attio IS
  'Whether this company currently exists in the Attio CRM. Used for pipeline synchronization.';

COMMENT ON COLUMN public.sourcing_view.last_stage_in_attio IS
  'Current pipeline stage of the company in the Attio CRM (e.g. Sourcing, First Contact, Due Diligence).';

COMMENT ON COLUMN public.sourcing_view.last_status_in_attio IS
  'Current status of the company in the Attio CRM.';

-- Dealroom enrichment
COMMENT ON COLUMN public.sourcing_view.headcount IS
  'Total employee count as reported by Dealroom, from the most recent Dealroom enrichment entry.';

COMMENT ON COLUMN public.sourcing_view.headcount_growth_l12m IS
  'Employee headcount growth over the last 12 months as reported by Dealroom, stored as percentage (e.g. 25.5 for 25.5%), from the most recent Dealroom enrichment entry.';

COMMENT ON COLUMN public.sourcing_view.web_traffic IS
  'Monthly web traffic (visits) as reported by Dealroom, from the most recent Dealroom enrichment entry.';

COMMENT ON COLUMN public.sourcing_view.web_traffic_growth_l12m IS
  'Web traffic growth over the last 12 months as reported by Dealroom, stored as percentage (e.g. 25.5 for 25.5%), from the most recent Dealroom enrichment entry.';