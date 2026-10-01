-- Juno — server mirror of the local drift schema.
--
-- Rows are keyed by (user_id, id): seeded rows use the same deterministic id
-- on every install, so ids are only unique per user. Row-level security keeps
-- every user inside their own rows.
--
-- `updated_at` is written by the client and decides last-write-wins.
-- `server_updated_at` is stamped by the server on every write and is the pull
-- cursor, so a device with a skewed clock can't slip changes past it.

create or replace function public.juno_touch() returns trigger
language plpgsql as $$
begin
  new.server_updated_at := now();
  return new;
end $$;

create or replace function public.juno_table(t text) returns void
language plpgsql as $$
begin
  execute format('alter table public.%I enable row level security', t);
  execute format('drop policy if exists own_rows on public.%I', t);
  execute format(
    'create policy own_rows on public.%I for all to authenticated
       using (user_id = auth.uid()) with check (user_id = auth.uid())', t);
  execute format('drop trigger if exists touch on public.%I', t);
  execute format(
    'create trigger touch before insert or update on public.%I
       for each row execute function public.juno_touch()', t);
  execute format(
    'create index if not exists %I on public.%I (user_id, server_updated_at)',
    t || '_cursor', t);
end $$;

create table if not exists public.accounts (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  name text not null,
  kind text not null,
  opening_balance_cents bigint not null default 0,
  currency text not null default 'USD',
  archived boolean not null default false,
  sort integer not null default 0,
  primary key (user_id, id)
);

create table if not exists public.categories (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  name text not null,
  icon text not null,
  color_index integer not null,
  kind text not null,
  default_scope text not null default 'personal',
  sort integer not null default 0,
  archived boolean not null default false,
  primary key (user_id, id)
);

create table if not exists public.transactions (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  type text not null,
  scope text not null,
  amount_cents bigint not null,
  account_id uuid not null,
  to_account_id uuid,
  category_id uuid,
  occurred_on date not null,
  note text not null default '',
  merchant text not null default '',
  recurring_id uuid,
  import_batch_id uuid,
  dedupe_hash text,
  primary key (user_id, id)
);

create table if not exists public.budgets (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  category_id uuid,
  scope text,
  limit_cents bigint not null,
  primary key (user_id, id)
);

create table if not exists public.goals (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  name text not null,
  target_cents bigint not null,
  target_date date,
  color_index integer not null default 0,
  archived boolean not null default false,
  primary key (user_id, id)
);

create table if not exists public.goal_contributions (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  goal_id uuid not null,
  amount_cents bigint not null,
  occurred_on date not null,
  note text not null default '',
  primary key (user_id, id)
);

create table if not exists public.recurring_rules (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  type text not null,
  scope text not null,
  amount_cents bigint not null,
  account_id uuid not null,
  category_id uuid,
  note text not null default '',
  frequency text not null,
  "interval" integer not null default 1,
  anchor_date date not null,
  next_due date not null,
  end_date date,
  active boolean not null default true,
  primary key (user_id, id)
);

create table if not exists public.import_batches (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  filename text not null,
  row_count integer not null,
  primary key (user_id, id)
);

select public.juno_table(t) from unnest(array[
  'accounts', 'categories', 'transactions', 'budgets', 'goals',
  'goal_contributions', 'recurring_rules', 'import_batches'
]) as t;

-- Two devices materialising the same recurring occurrence converge on one row.
create unique index if not exists transactions_recurring_day
  on public.transactions (user_id, recurring_id, occurred_on)
  where recurring_id is not null;
