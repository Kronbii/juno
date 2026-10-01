-- Last-write-wins on the server too.
--
-- Without this, a device pushing an *older* version of a row (it edited
-- earlier but synced later) overwrote a newer one. The newer device had
-- already marked its edit as pushed, kept its own copy on pull (it is
-- newer), and never re-sent it — the two devices diverged for good.
--
-- Now an incoming row older than the stored one is ignored (the stored row
-- is kept), and server_updated_at is still bumped so every device re-pulls
-- the winner.
create or replace function public.juno_touch() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.updated_at < old.updated_at then
    new := old;
  end if;
  new.server_updated_at := now();
  return new;
end $$;
