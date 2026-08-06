-- ---------------------------------------------------------------------------
-- Table presets: one-click, shared "quick apply" buttons in the toolbar.
--   kind = 'filter'  -> config = { filterConfig: [...], sortConfig: [...] }
--   kind = 'columns' -> config = { columnOrder: [...], visibleColumns: [...] }
-- A preset only touches its dimension: a filter preset sets filters/sort and
-- leaves columns alone, a columns preset sets columns and leaves filters alone.
-- Editing = "update from current state" in the app -> shared with everyone.
-- Idempotent.
-- ---------------------------------------------------------------------------

create table if not exists public.table_presets (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null check (kind in ('filter', 'columns')),
  name       text not null,
  config     jsonb not null default '{}'::jsonb,
  sort_order int  not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- RLS: mirror saved_views (full access for authenticated users).
alter table public.table_presets enable row level security;
drop policy if exists "Allow all for authenticated" on public.table_presets;
create policy "Allow all for authenticated"
  on public.table_presets
  for all
  to authenticated
  using (true)
  with check (true);

-- Seed the two default buttons, empty (filled in-app via "update from current").
insert into public.table_presets (id, kind, name, sort_order, config)
values
  ('cccccccc-0000-4000-8000-000000000001', 'filter',  'Equity fit',   1, '{"filterConfig":[],"sortConfig":[]}'::jsonb),
  ('cccccccc-0000-4000-8000-000000000002', 'columns', 'Main columns', 2, '{"columnOrder":[],"visibleColumns":[]}'::jsonb)
on conflict (id) do nothing;
