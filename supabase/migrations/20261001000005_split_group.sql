-- Split entries: parts of one payment share a group id.
alter table public.transactions add column if not exists split_group uuid;
