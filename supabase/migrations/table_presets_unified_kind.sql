-- ---------------------------------------------------------------------------
-- Unified table presets.
-- Presets used to be narrow: kind 'filter' (filters + sort) or 'columns'
-- (columns only). A preset created in the app now captures everything at once:
--   kind = 'all' -> config = {
--     filterConfig: [...], sortConfig: [...],
--     columnOrder: [...], visibleColumns: [...]
--   }
-- Existing 'filter' / 'columns' rows keep working unchanged.
-- Idempotent.
-- ---------------------------------------------------------------------------

alter table public.table_presets
  drop constraint if exists table_presets_kind_check;

alter table public.table_presets
  add constraint table_presets_kind_check
  check (kind in ('filter', 'columns', 'all'));
