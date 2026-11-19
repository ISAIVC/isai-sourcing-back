-- sourcing_mv : last_stage_in_attio prend la valeur manuelle en priorite.
--
-- Probleme : le front ecrit le stade Attio edite a la main dans
-- companies.last_stage_in_attio_manual (HomePage.jsx, MANUAL_COLUMN), et
-- sourcing_view le lisait, mais sourcing_mv (lue par le front) utilisait
-- seulement bcv.attio_stage. Apres le refresh du cron (15 min), la valeur
-- saisie disparaissait. present_in_attio et last_status_in_attio etaient deja OK.
--
-- Une vue materialisee ne se modifie pas en place : on la recree. La vue
-- sourcing_by_fund en depend, on la recree aussi. Les fonctions search_companies,
-- match_companies_filtered et match_competitors ne sont pas concernees
-- (types de retour explicites, colonnes inchangees).
--
-- Colonnes et ordre identiques a la definition en production au 2026-11-19
-- (58 colonnes pour sourcing_mv, 60 pour sourcing_by_fund).
-- A appliquer en une seule transaction (migration Supabase). Coupure breve du
-- tableau le temps de la recreation.

-- Le calcul de la vue (~4 min) depasse le delai de l'editeur SQL : on cree la
-- vue VIDE (WITH NO DATA, instantane), puis un job pg_cron unique la remplit en
-- arriere-plan et se supprime ensuite (voir la fin du fichier).
-- A lancer HORS d'un refresh du cron (qui tourne aux minutes :00 :15 :30 :45 et
-- dure ~4 min) : lock_timeout fait echouer proprement le script si un refresh
-- est en cours, il suffit alors de le relancer quelques minutes plus tard.
-- Tant que la vue n'est pas remplie, le tableau du front affiche une erreur.

BEGIN;

SET LOCAL lock_timeout = '20s';

DROP VIEW IF EXISTS public.sourcing_by_fund;
DROP MATERIALIZED VIEW IF EXISTS public.sourcing_mv;

CREATE MATERIALIZED VIEW public.sourcing_mv AS
 SELECT COALESCE(c.scope_manual, bcv.scope) AS fund_prime_scope,
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
    COALESCE(c.in_attio_manual, bcv.in_attio) AS present_in_attio,
    COALESCE(c.last_stage_in_attio_manual, bcv.attio_stage) AS last_stage_in_attio,  -- seule ligne modifiee
    COALESCE(c.attio_status_manual, bcv.attio_status) AS last_status_in_attio,
    dre.headcount,
    dre.headcount_growth_l12m,
    dre.web_traffic,
    dre.web_traffic_growth_l12m,
    ce.full_embedding,
    bcv.founder_background_category,
    bcv.notable_education
   FROM companies c
     LEFT JOIN business_computed_values bcv ON bcv.domain = c.domain
     LEFT JOIN LATERAL ( SELECT w.description,
            w.detailed_solution,
            w.use_cases,
            w.key_clients,
            w.nb_of_clients_identified
           FROM web_scraping_enrichment w
          WHERE w.domain = c.domain
          ORDER BY w.sourcing_date DESC NULLS LAST
         LIMIT 1) wse ON true
     LEFT JOIN LATERAL ( SELECT d.headcount,
            d.headcount_growth_l12m,
            d.web_traffic,
            d.web_traffic_growth_l12m
           FROM dealroom_enrichment d
          WHERE d.domain = c.domain
          ORDER BY d.sourcing_date DESC NULLS LAST
         LIMIT 1) dre ON true
     LEFT JOIN company_embeddings ce ON ce.domain = c.domain
WITH NO DATA;

-- Index unique requis par REFRESH MATERIALIZED VIEW CONCURRENTLY
CREATE UNIQUE INDEX sourcing_mv_website_idx ON public.sourcing_mv USING btree (website);

GRANT ALL ON public.sourcing_mv TO authenticated, service_role;

CREATE VIEW public.sourcing_by_fund AS
 SELECT l.fund_id,
    m.fund_prime_scope, m.logo, m.name, m.website, m.hq_country, m.hq_city, m.inc_date,
    m.description, m.detailed_solution, m.use_cases, m.clients_served,
    m.number_of_clients_identified, m.global_2000_clients, m.cg_key_platforms,
    m.by_key_platforms, m.competitors_cg, m.competitors_by, m.affiliates_cg,
    m.affiliates_by, m.gtm_target_cg, m.gtm_target_by, m.vc_current_stage,
    m.first_vc_round_date, m.first_vc_round_amount, m.total_amount_raised,
    m.last_funding_amount, m.last_funding_date, m.all_investors,
    m.last_round_lead_investors, m.total_nber_of_rounds, m.business_model,
    m.founders_background, m.serial_entrepreneur, m.primary_sector_served_cg,
    m.primary_industry_served_cg, m.primary_sector_served_by, m.primary_industry_served_by,
    m.all_industries_served, m.business_mapping, m.tech_tags, m.solution_fit_cg,
    m.solution_fit_by, m.business_fit_cg, m.business_fit_by, m.maturity_fit,
    m.equity_score, m.traction_score, m.global_fund_score, m.present_in_attio,
    m.last_stage_in_attio, m.last_status_in_attio, m.headcount, m.headcount_growth_l12m,
    m.web_traffic, m.web_traffic_growth_l12m, m.full_embedding,
    m.founder_background_category, m.notable_education,
    l.created_at AS linked_at
   FROM fund_company_links l
     JOIN sourcing_mv m ON m.website = l.website
  WHERE l.excluded = false;

GRANT ALL ON public.sourcing_by_fund TO anon, authenticated, service_role;

-- Premier remplissage en arriere-plan (REFRESH non concurrent, obligatoire tant
-- que la vue est vide). Le job s'execute a la minute suivante puis se supprime.
-- Le cron habituel (refresh_sourcing_mv_if_dirty, CONCURRENTLY) reprend ensuite.
SELECT cron.schedule(
  'sourcing-mv-first-populate',
  '* * * * *',
  $job$SET statement_timeout = 0; REFRESH MATERIALIZED VIEW public.sourcing_mv; SELECT cron.unschedule('sourcing-mv-first-populate');$job$
);

COMMIT;
