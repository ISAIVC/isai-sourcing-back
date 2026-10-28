-- Startups « prio call » (28/10/2026) : à évoquer pendant un call avec un fonds.
-- Flag global sur la startup (meme valeur pour tous les fonds), lu en direct dans
-- `companies` par le front (pas via sourcing_mv) -> effet immediat, sans attendre le
-- refresh de 15 min. Pose via l'etoile du front ou le gabarit P du projet partage.
-- NON APPLIQUEE : a appliquer a la main apres validation (additif, sans reecriture de table).
alter table public.companies
  add column if not exists call_priority boolean not null default false;

-- Les policies existantes sur companies (update par `authenticated`) couvrent la colonne.
-- Index partiel : le front ne lit que les lignes en prio.
create index if not exists companies_call_priority_idx
  on public.companies (domain) where call_priority;
