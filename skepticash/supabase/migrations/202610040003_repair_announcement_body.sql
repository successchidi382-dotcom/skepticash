begin;

alter table public.announcements
  add column if not exists body text not null default '';

notify pgrst, 'reload schema';

commit;
 