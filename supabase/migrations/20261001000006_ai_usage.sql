-- AI spend per user per month, written only by the `ai` edge function (which
-- holds the OpenAI key) so the monthly cap is enforced on the server.

create table if not exists public.ai_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  month text not null check (month ~ '^\d{4}-\d{2}$'),
  spent_micros bigint not null default 0,
  calls integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, month)
);

alter table public.ai_usage enable row level security;

-- Users may read their own usage; nobody but the service role writes it.
drop policy if exists "ai_usage read own" on public.ai_usage;
create policy "ai_usage read own" on public.ai_usage
  for select using (user_id = auth.uid());

-- Atomic add, so two devices asking at once can't lose a charge.
create or replace function public.ai_charge(p_user uuid, p_month text, p_micros bigint)
returns bigint
language sql
security definer
set search_path = public
as $$
  insert into public.ai_usage (user_id, month, spent_micros, calls)
  values (p_user, p_month, greatest(p_micros, 0), 1)
  on conflict (user_id, month) do update
    set spent_micros = ai_usage.spent_micros + greatest(excluded.spent_micros, 0),
        calls = ai_usage.calls + 1,
        updated_at = now()
  returning spent_micros;
$$;

revoke all on function public.ai_charge(uuid, text, bigint) from public, anon, authenticated;
grant execute on function public.ai_charge(uuid, text, bigint) to service_role;
