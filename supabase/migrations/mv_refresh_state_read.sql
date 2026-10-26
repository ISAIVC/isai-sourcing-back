-- Lecture de mv_refresh_state par le front (26/10/2026).
-- Le front garde les editions manuelles par-dessus les lignes de sourcing_mv
-- jusqu'a ce que last_refreshed_at soit posterieur a la modif
-- (isai-sourcing-front/src/utils/pendingEdits.js). Sans ce droit, il se rabat
-- sur une duree fixe de 35 min.
-- NON APPLIQUEE : a appliquer a la main apres validation.
grant select on public.mv_refresh_state to authenticated;

drop policy if exists "read mv_refresh_state" on public.mv_refresh_state;
create policy "read mv_refresh_state" on public.mv_refresh_state
  for select to authenticated using (true);
