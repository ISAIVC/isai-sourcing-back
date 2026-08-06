-- ---------------------------------------------------------------------------
-- View folders + creator attribution.
--
-- Two independent dimensions on a saved view / list:
--   * folder      -> what it's attached to (BY, CAP, ...). One folder per view.
--   * created_by  -> who made it (Simon, Domitille, Arthur, Arnaud). Chosen
--                    at creation time.
-- "Simon's view in BY" = a view with folder_id = BY and created_by = 'Simon'.
--
-- Folders are NOT access control: every folder is visible to everyone.
-- Idempotent: safe to run multiple times.
-- ---------------------------------------------------------------------------

create table if not exists public.view_folders (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  kind       text not null default 'team' check (kind in ('team', 'personal')),
  sort_order int  not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Attach saved views to a folder. null folder_id = "no folder" (top level).
-- on delete set null: deleting a folder keeps its views (they become ungrouped).
alter table public.saved_views
  add column if not exists folder_id uuid
  references public.view_folders(id) on delete set null;

create index if not exists saved_views_folder_id_idx
  on public.saved_views (folder_id);

-- Creator attribution on views and lists (person's name).
alter table public.saved_views
  add column if not exists created_by text;

alter table public.saved_lists
  add column if not exists created_by text;

-- Row-level security: mirror saved_views (full access for authenticated users).
-- Without a policy, RLS-enabled tables deny everything.
alter table public.view_folders enable row level security;
drop policy if exists "Allow all for authenticated" on public.view_folders;
create policy "Allow all for authenticated"
  on public.view_folders
  for all
  to authenticated
  using (true)
  with check (true);

-- Seed the team folders with fixed UUIDs (idempotent).
insert into public.view_folders (id, name, kind, sort_order)
values
  ('bbbbbbbb-0000-4000-8000-000000000001', 'BY',  'team', 1),
  ('bbbbbbbb-0000-4000-8000-000000000002', 'CAP', 'team', 2)
on conflict (id) do nothing;
