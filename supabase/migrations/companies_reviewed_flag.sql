-- 2026-10-21 — Etat « revue » explicite pour le mode fonds du front (deja applique en base, migration companies_reviewed_flag).
alter table public.companies
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by text;

comment on column public.companies.reviewed_at is 'Date a laquelle un humain a marque la boite revue dans Dani (bouton Revue, ou edition manuelle du solution fit). Jamais rempli par Claude ni par le pipeline.';
comment on column public.companies.reviewed_by is 'Email de la personne qui a marque revue ; ''backfill'' = note manuelle solution fit 1-2 anterieure au 20/10/2026, consideree humaine.';

-- Backfill : notes manuelles 1-2 posees avant le 20/10/2026 (avant les analyses de portefeuille par Claude) = revues.
-- updated_at preserve (trigger desactive le temps du backfill). 4 219 lignes le 21/10/2026.
alter table public.companies disable trigger update_companies_updated_at;
update public.companies
set reviewed_at = updated_at, reviewed_by = 'backfill'
where reviewed_at is null
  and (solution_fit_cg_manual is not null or solution_fit_by_manual is not null)
  and least(coalesce(solution_fit_cg_manual, 9), coalesce(solution_fit_by_manual, 9)) <= 2
  and updated_at < '2026-10-20';
alter table public.companies enable trigger update_companies_updated_at;
