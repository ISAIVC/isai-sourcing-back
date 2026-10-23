-- 2026-10-23 — Date de derniere analyse de portefeuille d'un fonds + date de rattachement des startups (mode fonds du front).
-- Seule exception a la regle « aucune nouvelle colonne » de l'analyse de portefeuille (validee par Simon le 23/10/2026).

alter table public.funds
  add column if not exists last_analysis_at timestamptz;

comment on column public.funds.last_analysis_at is 'Fin de la derniere analyse de portefeuille du fonds (projet Claude « analyse de portefeuille », gabarit O). Les startups rattachees apres cette date (fund_company_links.created_at) sont « nouvelles » dans le front.';

-- sourcing_by_fund : ajout de linked_at (= fund_company_links.created_at), en derniere colonne.
-- refresh_fund_company_links() ne reecrit pas created_at (ON CONFLICT met a jour n_rounds, is_lead_any, last_round_date, updated_at).
create or replace view public.sourcing_by_fund as
 SELECT l.fund_id,
    m.fund_prime_scope, m.logo, m.name, m.website, m.hq_country, m.hq_city, m.inc_date,
    m.description, m.detailed_solution, m.use_cases, m.clients_served, m.number_of_clients_identified,
    m.global_2000_clients, m.cg_key_platforms, m.by_key_platforms, m.competitors_cg, m.competitors_by,
    m.affiliates_cg, m.affiliates_by, m.gtm_target_cg, m.gtm_target_by, m.vc_current_stage,
    m.first_vc_round_date, m.first_vc_round_amount, m.total_amount_raised, m.last_funding_amount,
    m.last_funding_date, m.all_investors, m.last_round_lead_investors, m.total_nber_of_rounds,
    m.business_model, m.founders_background, m.serial_entrepreneur, m.primary_sector_served_cg,
    m.primary_industry_served_cg, m.primary_sector_served_by, m.primary_industry_served_by,
    m.all_industries_served, m.business_mapping, m.tech_tags, m.solution_fit_cg, m.solution_fit_by,
    m.business_fit_cg, m.business_fit_by, m.maturity_fit, m.equity_score, m.traction_score,
    m.global_fund_score, m.present_in_attio, m.last_stage_in_attio, m.last_status_in_attio,
    m.headcount, m.headcount_growth_l12m, m.web_traffic, m.web_traffic_growth_l12m,
    m.full_embedding, m.founder_background_category, m.notable_education,
    l.created_at AS linked_at
   FROM fund_company_links l
     JOIN sourcing_mv m ON m.website = l.website
  WHERE l.excluded = false;

-- Backfill (23/10/2026) : fonds deja analyses avant la colonne = ceux qui ont des liens manuels ;
-- last_analysis_at = date du dernier lien manuel (approximation). 5 fonds : 1st Kind, Blackhorn Ventures,
-- Concept Ventures, Elaia, N47 (Siemens).
update public.funds f set last_analysis_at = x.t
from (select fund_id, max(created_at) t from public.fund_company_links where source = 'manual' group by fund_id) x
where x.fund_id = f.id and f.last_analysis_at is null;
