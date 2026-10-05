begin;

create table if not exists public.task_media_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  task_id uuid not null references public.tasks (id) on delete cascade,
  task_date date not null,
  started_at timestamptz not null default now(),
  status text not null default 'started' check (status in ('started', 'completed', 'missed')),
  completed_at timestamptz,
  unique (user_id, task_id, task_date) 
);

create index if not exists task_media_attempts_user_day_idx
  on public.task_media_attempts (user_id, task_date);

alter table public.task_media_attempts enable row level security;
drop policy if exists "task media attempts read own or admin" on public.task_media_attempts;
create policy "task media attempts read own or admin"
  on public.task_media_attempts for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));
grant select on public.task_media_attempts to authenticated;

create table if not exists public.vip_payment_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  plan_level integer not null references public.vip_plans (level),
  full_name text not null,
  email text not null,
  amount numeric(14, 2) not null check (amount > 0),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'expired')),
  payment_submitted_at timestamptz,
  admin_note text not null default '',
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '25 minutes')
);

create index if not exists vip_payment_requests_status_created_idx
  on public.vip_payment_requests (status, created_at desc);
create index if not exists vip_payment_requests_user_created_idx
  on public.vip_payment_requests (user_id, created_at desc);

alter table public.vip_payment_requests enable row level security;
drop policy if exists "vip payment requests read own or admin" on public.vip_payment_requests;
create policy "vip payment requests read own or admin"
  on public.vip_payment_requests for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));
grant select on public.vip_payment_requests to authenticated;

create or replace function public.begin_task_media(p_task_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  today_date date := (now() at time zone 'Africa/Lagos')::date;
  task_row public.tasks%rowtype;
  current_plan_level integer;
  allowed_tasks integer;
  completed_tasks integer;
  attempt_row public.task_media_attempts%rowtype;
begin
  if current_user_id is null then
    raise exception 'Sign in to start this task.';
  end if;

  select vip_level into current_plan_level
  from public.profiles
  where id = current_user_id and role = 'user'
  for update;
  if not found then
    raise exception 'Member account not found.';
  end if;

  select daily_tasks into allowed_tasks
  from public.vip_plans
  where level = current_plan_level;
  if allowed_tasks is null then
    raise exception 'An active VIP plan is required to complete tasks.';
  end if;

  select * into task_row
  from public.tasks
  where id = p_task_id and active and media_path is not null
  for update;
  if not found then
    raise exception 'This image task is no longer available.';
  end if;

  select count(*) into completed_tasks
  from public.task_completions
  where user_id = current_user_id and task_date = today_date;
  if completed_tasks >= allowed_tasks then
    raise exception 'You have completed today''s available tasks.';
  end if;
  if exists (
    select 1 from public.task_completions
    where user_id = current_user_id
      and task_id = p_task_id
      and task_date = today_date
  ) then
    raise exception 'You have already completed this task today.';
  end if;

  insert into public.task_media_attempts (user_id, task_id, task_date)
  values (current_user_id, p_task_id, today_date)
  returning * into attempt_row;

  return jsonb_build_object(
    'attempt_id', attempt_row.id,
    'started_at', attempt_row.started_at
  );
exception
  when unique_violation then
    raise exception 'You have already tried this task today. You can try again tomorrow.';
end;
$$;

create or replace function public.finish_task_media(p_attempt_id uuid, p_touched boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  today_date date := (now() at time zone 'Africa/Lagos')::date;
  attempt_row public.task_media_attempts%rowtype;
  task_row public.tasks%rowtype;
  current_plan_level integer;
  allowed_tasks integer;
  completed_tasks integer;
  completion_row public.task_completions%rowtype;
begin
  if current_user_id is null then
    raise exception 'Sign in to complete this task.';
  end if;

  select vip_level into current_plan_level
  from public.profiles
  where id = current_user_id
  for update;

  select * into attempt_row
  from public.task_media_attempts
  where id = p_attempt_id and user_id = current_user_id
  for update;
  if not found then
    raise exception 'This task attempt is unavailable.';
  end if;
  if attempt_row.status <> 'started' then
    raise exception 'This task has already been attempted today.';
  end if;

  if not coalesce(p_touched, false)
     or now() > attempt_row.started_at + interval '10 seconds'
     or attempt_row.task_date <> today_date then
    update public.task_media_attempts
    set status = 'missed'
    where id = attempt_row.id;
    return jsonb_build_object('status', 'missed');
  end if;

  select daily_tasks into allowed_tasks
  from public.vip_plans
  where level = current_plan_level;
  if allowed_tasks is null then
    update public.task_media_attempts set status = 'missed' where id = attempt_row.id;
    return jsonb_build_object('status', 'missed');
  end if;

  select count(*) into completed_tasks
  from public.task_completions
  where user_id = current_user_id and task_date = today_date;
  if completed_tasks >= allowed_tasks then
    update public.task_media_attempts set status = 'missed' where id = attempt_row.id;
    return jsonb_build_object('status', 'missed');
  end if;

  select * into task_row
  from public.tasks
  where id = attempt_row.task_id and active and media_path is not null
  for update;
  if not found then
    update public.task_media_attempts set status = 'missed' where id = attempt_row.id;
    return jsonb_build_object('status', 'missed');
  end if;

  insert into public.task_completions (user_id, task_id, task_date, reward_amount)
  values (current_user_id, task_row.id, today_date, task_row.reward_amount)
  returning * into completion_row;

  update public.wallets
  set balance = balance + task_row.reward_amount, updated_at = now()
  where user_id = current_user_id;
  if not found then
    raise exception 'Member wallet not found.';
  end if;

  insert into public.transactions (user_id, type, amount, status, description)
  values (current_user_id, 'task', task_row.reward_amount, 'completed', task_row.title);

  update public.task_media_attempts
  set status = 'completed', completed_at = now()
  where id = attempt_row.id;

  return jsonb_build_object(
    'status', 'completed',
    'completion_id', completion_row.id,
    'reward_amount', completion_row.reward_amount
  );
end;
$$;

create or replace function public.complete_task(p_task_id uuid)
returns public.task_completions
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  today_date date := (now() at time zone 'Africa/Lagos')::date;
  current_plan_level integer;
  allowed_tasks integer;
  completed_tasks integer;
  task_row public.tasks%rowtype;
  completion_row public.task_completions%rowtype;
begin
  if current_user_id is null then
    raise exception 'Sign in to complete a task.';
  end if;

  select vip_level into current_plan_level
  from public.profiles where id = current_user_id for update;
  select daily_tasks into allowed_tasks
  from public.vip_plans where level = current_plan_level;
  if allowed_tasks is null then
    raise exception 'An active VIP plan is required to complete tasks.';
  end if;

  select count(*) into completed_tasks
  from public.task_completions
  where user_id = current_user_id and task_date = today_date;
  if completed_tasks >= allowed_tasks then
    raise exception 'You have completed today''s available tasks.';
  end if;

  select * into task_row
  from public.tasks
  where id = p_task_id and active = true
  for update;
  if not found then
    raise exception 'This task is no longer available.';
  end if;
  if task_row.media_path is not null then
    raise exception 'Tap the task image within 10 seconds to complete this task.';
  end if;

  insert into public.task_completions (user_id, task_id, task_date, reward_amount)
  values (current_user_id, task_row.id, today_date, task_row.reward_amount)
  returning * into completion_row;

  update public.wallets
  set balance = balance + task_row.reward_amount, updated_at = now()
  where user_id = current_user_id;

  insert into public.transactions (user_id, type, amount, status, description)
  values (current_user_id, 'task', task_row.reward_amount, 'completed', task_row.title);

  return completion_row;
end;
$$;

drop function if exists public.create_vip_payment_request(integer, text, text);
create function public.create_vip_payment_request(
  p_plan_level integer,
  p_full_name text,
  p_email text
)
returns public.vip_payment_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  registered_email text;
  current_vip_level integer;
  selected_plan public.vip_plans%rowtype;
  request_row public.vip_payment_requests%rowtype;
begin
  if current_user_id is null then
    raise exception 'Sign in to request a VIP upgrade.';
  end if;
  if nullif(trim(p_full_name), '') is null or length(trim(p_full_name)) > 160 then
    raise exception 'Enter your full name (up to 160 characters).';
  end if;
  if p_email is null or length(trim(p_email)) > 320
     or trim(p_email) !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then
    raise exception 'Enter a valid email address.';
  end if;
  select email into registered_email
  from auth.users where id = current_user_id;
  if registered_email is null or lower(trim(p_email)) <> lower(registered_email) then
    raise exception 'Use the email address registered to your signed-in account.';
  end if;
  select vip_level into current_vip_level
  from public.profiles where id = current_user_id for update;
  if p_plan_level is null or p_plan_level <= coalesce(current_vip_level, 0) then
    raise exception 'Select a VIP level higher than your current level.';
  end if;
  select * into selected_plan
  from public.vip_plans where level = p_plan_level;
  if not found then
    raise exception 'That VIP plan is not available.';
  end if;
  if selected_plan.upgrade_cost <= 0 then
    raise exception 'This VIP plan does not have a payable price configured.';
  end if;
  perform public.get_manual_deposit_details();

  insert into public.vip_payment_requests (
    user_id, plan_level, full_name, email, amount, status, expires_at
  )
  values (
    current_user_id, selected_plan.level, trim(p_full_name),
    lower(trim(p_email)), selected_plan.upgrade_cost, 'pending',
    now() + interval '25 minutes'
  )
  returning * into request_row;
  return request_row;
end;
$$;

create or replace function public.confirm_vip_payment(p_request_id uuid)
returns public.vip_payment_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  request_row public.vip_payment_requests%rowtype;
begin
  if current_user_id is null then
    raise exception 'Sign in to confirm your payment.';
  end if;
  select * into request_row
  from public.vip_payment_requests
  where id = p_request_id and user_id = current_user_id
  for update;
  if not found or request_row.status <> 'pending' then
    raise exception 'This VIP payment request is no longer pending.';
  end if;
  if request_row.expires_at <= now() then
    update public.vip_payment_requests
    set status = 'expired'
    where id = p_request_id
    returning * into request_row;
    return request_row;
  end if;
  update public.vip_payment_requests
  set payment_submitted_at = coalesce(payment_submitted_at, now())
  where id = p_request_id
  returning * into request_row;
  return request_row;
end;
$$;

create or replace function public.expire_vip_payment(p_request_id uuid)
returns public.vip_payment_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  request_row public.vip_payment_requests%rowtype;
begin
  if current_user_id is null then
    raise exception 'Sign in to close this VIP payment request.';
  end if;
  update public.vip_payment_requests
  set status = 'expired'
  where id = p_request_id
    and user_id = current_user_id
    and status = 'pending'
    and expires_at <= now()
  returning * into request_row;
  if not found then
    raise exception 'This VIP payment request has not expired or is no longer pending.';
  end if;
  return request_row;
end;
$$;

create or replace function public.admin_expire_vip_payments()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  affected_rows integer;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;
  update public.vip_payment_requests
  set status = 'expired'
  where status = 'pending'
    and payment_submitted_at is null
    and expires_at <= now();
  get diagnostics affected_rows = row_count;
  return affected_rows;
end;
$$;

create or replace function public.admin_review_vip_payment(
  p_request_id uuid,
  p_decision text,
  p_admin_note text default ''
)
returns public.vip_payment_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_row public.vip_payment_requests%rowtype;
  current_vip_level integer;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Invalid VIP payment decision.';
  end if;
  if length(coalesce(p_admin_note, '')) > 500 then
    raise exception 'Review note must be 500 characters or fewer.';
  end if;

  select * into request_row
  from public.vip_payment_requests
  where id = p_request_id
  for update;
  if not found then
    raise exception 'VIP payment request not found.';
  end if;
  if request_row.status not in ('pending', 'rejected', 'expired') then
    raise exception 'Only unapproved VIP payment requests can be reviewed.';
  end if;
  if p_decision = 'approved' then
    select vip_level into current_vip_level
    from public.profiles
    where id = request_row.user_id and role = 'user'
    for update;
    if not found then
      raise exception 'Member account not found.';
    end if;
    if current_vip_level >= request_row.plan_level then
      raise exception 'The member already has this VIP level or a higher one.';
    end if;
    update public.profiles
    set vip_level = request_row.plan_level
    where id = request_row.user_id;
  end if;

  update public.vip_payment_requests
  set status = p_decision,
      admin_note = coalesce(trim(p_admin_note), ''),
      reviewed_by = (select auth.uid()),
      reviewed_at = now()
  where id = p_request_id
  returning * into request_row;
  return request_row;
end;
$$;

revoke all on function public.begin_task_media(uuid) from public, anon;
grant execute on function public.begin_task_media(uuid) to authenticated;
revoke all on function public.finish_task_media(uuid, boolean) from public, anon;
grant execute on function public.finish_task_media(uuid, boolean) to authenticated;
revoke all on function public.complete_task(uuid) from public, anon;
grant execute on function public.complete_task(uuid) to authenticated;
revoke all on function public.create_vip_payment_request(integer, text, text) from public, anon;
grant execute on function public.create_vip_payment_request(integer, text, text) to authenticated;
revoke all on function public.confirm_vip_payment(uuid) from public, anon;
grant execute on function public.confirm_vip_payment(uuid) to authenticated;
revoke all on function public.expire_vip_payment(uuid) from public, anon;
grant execute on function public.expire_vip_payment(uuid) to authenticated;
revoke all on function public.admin_expire_vip_payments() from public, anon;
grant execute on function public.admin_expire_vip_payments() to authenticated;
revoke all on function public.admin_review_vip_payment(uuid, text, text) from public, anon;
grant execute on function public.admin_review_vip_payment(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';

commit;
