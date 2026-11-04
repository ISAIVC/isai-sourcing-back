-- Commentaire de revue (04/11/2026) : petit texte libre saisi a la main quand Simon marque une
-- startup « vue » (fonds ou liste), ex. « concurrent de X », « pas pour Capgemini ».
-- Global sur la startup (comme reviewed_at), lu en direct dans `companies` par le front.
-- NON APPLIQUEE : a appliquer a la main apres validation (additif, nullable).
-- Sans cette colonne le front fonctionne toujours (marquage « vu » inchange) ; seuls les
-- commentaires sont indisponibles.
alter table public.companies
  add column if not exists review_comment text;
