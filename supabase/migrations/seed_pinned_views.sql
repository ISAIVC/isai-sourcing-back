-- ---------------------------------------------------------------------------
-- Seed the two pinned "Top deals" views with fixed UUIDs.
-- The front references these ids (src/utils/builtinViews.js) to pin them at
-- the top of the sidebar and to drive the Deal flow dashboard.
-- Idempotent: safe to run multiple times (on conflict do nothing).
-- ---------------------------------------------------------------------------

insert into saved_views (id, name, configuration)
values
  (
    'aaaaaaaa-0000-4000-8000-000000000001',
    'Top deals CG',
    '{"sortConfig":[{"col":"last_funding_date","dir":"desc"}],"filterConfig":[{"col":"solution_fit_cg","op":"lte","value":2}],"semanticQuery":null}'::jsonb
  ),
  (
    'aaaaaaaa-0000-4000-8000-000000000002',
    'Top deals BY',
    '{"sortConfig":[{"col":"last_funding_date","dir":"desc"}],"filterConfig":[{"col":"solution_fit_by","op":"lte","value":2}],"semanticQuery":null}'::jsonb
  )
on conflict (id) do nothing;
