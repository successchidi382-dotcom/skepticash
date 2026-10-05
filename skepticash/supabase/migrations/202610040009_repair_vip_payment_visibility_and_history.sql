begin;

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
  transaction_id uuid,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '25 minutes')
);

alter table public.vip_payment_requests
  add column if not exists payment_submitted_at timestamptz,
  add column if not exists admin_note text not null default '',
  add column if not exists reviewed_by uuid references public.profiles (id),
  add column if not exists reviewed_at timestamptz,
  add column if not exists transaction_id uuid,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists expires_at timestamptz not null default (now() + interval '25 minutes');

create index if not exists vip_payment_requests_status_created_idx
  on public.vip_payment_requests (status, created_at desc);
create index if not exists vip_payment_requests_user_created_idx
  on public.vip_payment_requests (user_id, created_at desc);
create unique index if not exists vip_payment_requests_transaction_id_idx
  on public.vip_payment_requests (transaction_id)
  where transaction_id is not null;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.vip_payment_requests'::regclass
      and conname = 'vip_payment_requests_transaction_id_fkey'
  ) then
    alter table public.vip_payment_requests
      add constraint vip_payment_requests_transaction_id_fkey
      foreign key (transaction_id) references public.transactions (id) on delete set null;
  end if;
end;
$$;

do $$
declare
  constraint_row record;
begin
  for constraint_row in
    select conname
    from pg_catalog.pg_constraint
    where conrelid = 'public.transactions'::regclass
      and contype = 'c'
      and pg_catalog.pg_get_constraintdef(oid) ilike '%type%'
  loop
    execute pg_catalog.format('alter table public.transactions drop constraint %I', constraint_row.conname);
  end loop;
end;
$$;

alter table public.transactions
  add constraint transactions_type_check
  check (type in ('deposit', 'withdrawal', 'task', 'adjustment', 'vip_purchase'));

do $$
declare
  constraint_row record;
begin
  for constraint_row in
    select conname
    from pg_catalog.pg_constraint
    where conrelid = 'public.transactions'::regclass
      and contype = 'c'
      and pg_catalog.pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute pg_catalog.format('alter table public.transactions drop constraint %I', constraint_row.conname);
  end loop;
end;
$$;

alter table public.transactions
  add constraint transactions_status_check
  check (status in ('pending', 'completed', 'approved', 'rejected', 'failed', 'expired'));

create index if not exists transactions_vip_purchase_user_created_idx
  on public.transactions (user_id, created_at desc)
  where type = 'vip_purchase';

alter table public.vip_payment_requests enable row level security;
drop policy if exists "vip payment requests read own or admin" on public.vip_payment_requests;
create policy "vip payment requests read own or admin"
  on public.vip_payment_requests for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));
grant select on public.vip_payment_requests to authenticated;

do $$
declare
  request_row public.vip_payment_requests%rowtype;
  linked_transaction_id uuid;
  transaction_status text;
  transaction_description text;
begin
  for request_row in
    select *
    from public.vip_payment_requests
    where transaction_id is null
    order by created_at, id
    for update
  loop
    transaction_status := case
      when request_row.status = 'approved' then 'approved'
      when request_row.status = 'rejected' then 'rejected'
      when request_row.status = 'expired' then 'expired'
      else 'pending'
    end;
    transaction_description := case
      when request_row.status = 'approved' then
        'VIP ' || request_row.plan_level::text || ' plan payment approved — VIP ' || request_row.plan_level::text || ' activated'
      when request_row.status = 'rejected' then
        'VIP ' || request_row.plan_level::text || ' plan payment rejected'
      when request_row.payment_submitted_at is not null then
        'VIP ' || request_row.plan_level::text || ' plan payment reported — awaiting admin approval'
      else
        'VIP ' || request_row.plan_level::text || ' plan payment request'
    end;

    insert into public.transactions (user_id, type, amount, status, description, created_at)
    values (
      request_row.user_id,
      'vip_purchase',
      request_row.amount,
      transaction_status,
      transaction_description,
      request_row.created_at
    )
    returning id into linked_transaction_id;

    update public.vip_payment_requests
    set transaction_id = linked_transaction_id
    where id = request_row.id;
  end loop;
end;
$$;

create or replace function public.create_vip_payment_request(
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
  transaction_row public.transactions%rowtype;
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
  from auth.users
  where id = current_user_id;
  if registered_email is null or lower(trim(p_email)) <> lower(registered_email) then
    raise exception 'Use the email address registered to your signed-in account.';
  end if;

  select vip_level into current_vip_level
  from public.profiles
  where id = current_user_id and role = 'user'
  for update;
  if not found then
    raise exception 'Member account not found.';
  end if;
  if p_plan_level is null or p_plan_level <= coalesce(current_vip_level, 0) then
    raise exception 'Select a VIP level higher than your current level.';
  end if;

  select * into selected_plan
  from public.vip_plans
  where level = p_plan_level;
  if not found or selected_plan.upgrade_cost <= 0 then
    raise exception 'That VIP plan does not have a payable price configured.';
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

  insert into public.transactions (user_id, type, amount, status, description)
  values (
    current_user_id,
    'vip_purchase',
    request_row.amount,
    'pending',
    'VIP ' || request_row.plan_level::text || ' plan payment request'
  )
  returning * into transaction_row;

  update public.vip_payment_requests
  set transaction_id = transaction_row.id
  where id = request_row.id
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
    update public.transactions
    set status = 'expired',
        description = 'VIP ' || request_row.plan_level::text || ' plan payment expired'
    where id = request_row.transaction_id;
    return request_row;
  end if;

  update public.vip_payment_requests
  set payment_submitted_at = coalesce(payment_submitted_at, now())
  where id = p_request_id
  returning * into request_row;
  update public.transactions
  set description = 'VIP ' || request_row.plan_level::text || ' plan payment reported — awaiting admin approval'
  where id = request_row.transaction_id;
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

  update public.transactions
  set status = 'expired',
      description = 'VIP ' || request_row.plan_level::text || ' plan payment expired'
  where id = request_row.transaction_id;
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

  with expired as (
    update public.vip_payment_requests
    set status = 'expired'
    where status = 'pending'
      and payment_submitted_at is null
      and expires_at <= now()
    returning id, plan_level, transaction_id
  ), updated_transactions as (
    update public.transactions as tx
    set status = 'expired',
        description = 'VIP ' || expired.plan_level::text || ' plan payment expired'
    from expired
    where tx.id = expired.transaction_id
    returning tx.id
  )
  select count(*)::integer into affected_rows from expired;
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

  update public.transactions
  set status = p_decision,
      description = case
        when p_decision = 'approved' then
          'VIP ' || request_row.plan_level::text || ' plan payment approved — VIP ' || request_row.plan_level::text || ' activated'
        when request_row.admin_note = '' then
          'VIP ' || request_row.plan_level::text || ' plan payment rejected'
        else
          'VIP ' || request_row.plan_level::text || ' plan payment rejected — ' || request_row.admin_note
      end
  where id = request_row.transaction_id;

  return request_row;
end;
$$;

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
