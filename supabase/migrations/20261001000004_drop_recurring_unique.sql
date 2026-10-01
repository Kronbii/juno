-- Occurrence ids are deterministic per (rule, day), so this index added no
-- safety — and it rejected a legitimate push when an occurrence had been
-- moved onto another occurrence's date, which used to block all syncing.
drop index if exists public.transactions_recurring_day;
create index if not exists transactions_recurring on public.transactions (user_id, recurring_id);
