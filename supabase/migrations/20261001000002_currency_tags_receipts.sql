-- v2: multi-currency, tags, receipt attachments.

alter table public.transactions
  add column if not exists currency text not null default 'USD',
  add column if not exists base_cents bigint,
  add column if not exists to_amount_cents bigint,
  add column if not exists tags text not null default '';

create table if not exists public.currency_rates (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  code text not null,
  per_usd double precision not null,
  primary key (user_id, id)
);

create table if not exists public.attachments (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  transaction_id uuid not null,
  file_name text not null,
  mime text not null,
  size_bytes integer not null,
  uploaded boolean not null default false,
  primary key (user_id, id)
);

select public.juno_table(t) from unnest(array['currency_rates', 'attachments']) as t;

-- Receipt files: private bucket, each user confined to <their uid>/…
insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', false)
on conflict (id) do nothing;

drop policy if exists receipts_own on storage.objects;
create policy receipts_own on storage.objects for all to authenticated
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
