-- ---------------------------------------------------------------------------
-- "Tier 1 backed" toolbar preset.
--
-- Simpler alternative to a dedicated tier_1_investor column: filters the
-- EXISTING all_investors column (already present on sourcing_mv/
-- sourcing_view, already filterable as a multitag) against a static list of
-- tier-1 fund names (public.vc_funds where tier = 1, snapshotted below).
--
-- Trade-off vs a computed column: exact-string overlap instead of a
-- case/whitespace-insensitive match. Measured against the live data this
-- misses ~26 of 5827 matches (~0.4%) — accepted as negligible. The list is
-- static, so a future change to vc_funds.tier does not auto-propagate here;
-- re-run this migration (or edit the preset's config directly) if the
-- tier-1 fund list changes.
--
-- No schema change, no sourcing_mv rebuild, no timeout risk — a single
-- fast INSERT.
--
-- Idempotent: safe to run multiple times.
-- ---------------------------------------------------------------------------

INSERT INTO public.table_presets (id, kind, name, sort_order, config)
VALUES (
  'cccccccc-0000-4000-8000-000000000003',
  'filter',
  'Tier 1 backed',
  3,
  jsonb_build_object(
    'filterConfig', jsonb_build_array(
      jsonb_build_object(
        'col', 'all_investors',
        'op', 'overlaps',
        'value', (
          SELECT jsonb_agg(name ORDER BY name)
          FROM public.vc_funds
          WHERE tier = 1
        )
      )
    ),
    'sortConfig', jsonb_build_array()
  )
)
ON CONFLICT (id) DO UPDATE SET
  config = EXCLUDED.config,
  name = EXCLUDED.name,
  sort_order = EXCLUDED.sort_order;
