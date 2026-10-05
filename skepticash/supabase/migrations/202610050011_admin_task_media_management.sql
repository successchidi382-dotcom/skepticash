begin;

alter table public.tasks
  add column if not exists deleted_at timestamptz;

create index if not exists tasks_available_created_idx
  on public.tasks (created_at desc)
  where deleted_at is null;

notify pgrst, 'reload schema';

commit;
