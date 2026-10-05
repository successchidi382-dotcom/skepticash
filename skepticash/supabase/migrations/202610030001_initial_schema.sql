begin;

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  full_name text not null default '',
  role text not null default 'user' check (role in ('user', 'admin')),
  vip_level integer not null default 0 check (vip_level between 0 and 9),
  referral_code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)),
  referred_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.wallets (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  balance numeric(14, 2) not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.vip_plans (
  level integer primary key check (level between 1 and 9),
  upgrade_cost numeric(14, 2) not null check (upgrade_cost >= 0),
  daily_tasks integer not null check (daily_tasks > 0),
  task_commission numeric(14, 2) not null check (task_commission >= 0),
  daily_income numeric(14, 2) not null check (daily_income >= 0),
  updated_at timestamptz not null default now()
);

insert into public.vip_plans (level, upgrade_cost, daily_tasks, task_commission, daily_income)
values
  (1, 17900, 1, 680, 680),
  (2, 53000, 2, 975, 1950),
  (3, 165000, 3, 1950, 5850),
  (4, 392000, 4, 3575, 14300),
  (5, 962000, 5, 7100, 35500),
  (6, 2300000, 8, 10625, 85000),
  (7, 5112000, 10, 19700, 197000),
  (8, 11500000, 16, 29375, 470000),
  (9, 25620000, 20, 55200, 1104000)
on conflict (level) do nothing;

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null default '',
  reward_amount numeric(14, 2) not null check (reward_amount >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.tasks
  add column if not exists active boolean not null default true;

create table if not exists public.task_completions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  task_id uuid not null references public.tasks (id) on delete restrict,
  task_date date not null default (now() at time zone 'UTC')::date,
  reward_amount numeric(14, 2) not null check (reward_amount >= 0),
  created_at timestamptz not null default now(),
  unique (user_id, task_id, task_date)
);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  type text not null check (type in ('deposit', 'withdrawal', 'task', 'adjustment')),
  amount numeric(14, 2) not null check (amount >= 0),
  status text not null default 'completed' check (status in ('pending', 'completed', 'approved', 'rejected', 'failed')),
  description text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.withdrawals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  amount numeric(14, 2) not null check (amount > 0),
  transaction_id uuid references public.transactions (id),
  bank_name text not null,
  account_last4 text not null check (account_last4 ~ '^[0-9]{4}$'),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references public.profiles (id) on delete cascade,
  referred_user_id uuid not null references public.profiles (id) on delete cascade,
  level integer not null default 1 check (level between 1 and 3),
  commission_percent numeric(5, 2) not null default 15 check (commission_percent between 0 and 100),
  earnings numeric(14, 2) not null default 0 check (earnings >= 0),
  created_at timestamptz not null default now(),
  check (referrer_id <> referred_user_id),
  unique (referred_user_id, level)
);

alter table public.referrals
  add column if not exists referrer_id uuid references public.profiles (id) on delete cascade;

create table if not exists public.referral_commission_rates (
  level integer primary key check (level between 1 and 3),
  commission_percent numeric(5, 2) not null check (commission_percent between 0 and 100),
  updated_at timestamptz not null default now()
);

insert into public.referral_commission_rates (level, commission_percent)
values (1, 15), (2, 5), (3, 1)
on conflict (level) do nothing;

create table if not exists public.platform_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

insert into public.platform_settings (key, value)
values ('payments_enabled', 'false'::jsonb)
on conflict (key) do nothing;

create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  active boolean not null default true,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.announcements
  add column if not exists active boolean not null default true;

create index if not exists transactions_user_created_idx on public.transactions (user_id, created_at desc);
create index if not exists withdrawals_status_created_idx on public.withdrawals (status, created_at desc);
create index if not exists task_completions_user_date_idx on public.task_completions (user_id, task_date);
create index if not exists referrals_referrer_level_idx on public.referrals (referrer_id, level);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'admin'
  );
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  referrer_id uuid;
  ancestor_id uuid;
  referral_level integer;
  commission numeric(5, 2);
begin
  select id into referrer_id
  from public.profiles
  where referral_code = upper(coalesce(new.raw_user_meta_data ->> 'referral_code', ''))
    and id <> new.id;

  insert into public.profiles (id, email, full_name, referred_by)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    referrer_id
  );
  insert into public.wallets (user_id) values (new.id);
  if referrer_id is not null then
    ancestor_id := referrer_id;
    for referral_level in 1..3 loop
      select commission_percent into commission
      from public.referral_commission_rates as rates where rates.level = referral_level;
      if ancestor_id is null then
        exit;
      end if;
      insert into public.referrals (referrer_id, referred_user_id, level, commission_percent)
      values (ancestor_id, new.id, referral_level, coalesce(commission, 0));
      select referred_by into ancestor_id
      from public.profiles where id = ancestor_id;
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

insert into public.profiles (id, email, full_name)
select users.id, coalesce(users.email, ''), coalesce(users.raw_user_meta_data ->> 'full_name', '')
from auth.users as users
on conflict (id) do nothing;

insert into public.wallets (user_id)
select profiles.id from public.profiles
on conflict (user_id) do nothing;

create or replace function public.complete_task(p_task_id uuid)
returns public.task_completions
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
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
  where user_id = current_user_id and task_date = (now() at time zone 'UTC')::date;

  if completed_tasks >= allowed_tasks then
    raise exception 'You have completed today''s available tasks.';
  end if;

  select * into task_row from public.tasks
  where id = p_task_id and active = true for update;

  if not found then
    raise exception 'This task is no longer available.';
  end if;

  insert into public.task_completions (user_id, task_id, reward_amount)
  values (current_user_id, task_row.id, task_row.reward_amount)
  returning * into completion_row;

  update public.wallets
  set balance = balance + task_row.reward_amount, updated_at = now()
  where user_id = current_user_id;

  insert into public.transactions (user_id, type, amount, status, description)
  values (current_user_id, 'task', task_row.reward_amount, 'completed', task_row.title);

  return completion_row;
end;
$$;

create or replace function public.admin_update_member(p_user_id uuid, p_balance numeric, p_vip_level integer)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_balance numeric(14, 2);
  result_row public.profiles%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;
  if p_balance is null or p_balance < 0 or p_balance > 999999999999.99 then
    raise exception 'Balance must be zero or greater and within the supported limit.';
  end if;
  if p_vip_level is null or p_vip_level < 0 or p_vip_level > 9 then
    raise exception 'VIP level must be between 0 and 9.';
  end if;
  if p_vip_level > 0 and not exists (select 1 from public.vip_plans where level = p_vip_level) then
    raise exception 'That VIP plan does not exist.';
  end if;

  select balance into old_balance
  from public.wallets where user_id = p_user_id for update;
  if not found then
    raise exception 'Wallet not found.';
  end if;
  update public.wallets set balance = p_balance, updated_at = now()
  where user_id = p_user_id;
  update public.profiles set vip_level = p_vip_level
  where id = p_user_id returning * into result_row;
  if not found then
    raise exception 'Member not found.';
  end if;
  if old_balance <> p_balance then
    insert into public.transactions (user_id, type, amount, status, description)
    values (p_user_id, 'adjustment', abs(p_balance - old_balance), 'completed', 'Administrator balance adjustment');
  end if;
  return result_row;
end;
$$;

create or replace function public.admin_review_withdrawal(p_withdrawal_id uuid, p_decision text)
returns public.withdrawals
language plpgsql
security definer
set search_path = ''
as $$
declare
  withdrawal_row public.withdrawals%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Invalid withdrawal decision.';
  end if;
  update public.withdrawals
  set status = p_decision, reviewed_by = (select auth.uid()), reviewed_at = now()
  where id = p_withdrawal_id and status = 'pending'
  returning * into withdrawal_row;
  if not found then
    raise exception 'Pending withdrawal not found.';
  end if;
  if p_decision = 'rejected' then
    update public.wallets
    set balance = balance + withdrawal_row.amount, updated_at = now()
    where user_id = withdrawal_row.user_id;
  end if;
  update public.transactions
  set status = p_decision
  where id = withdrawal_row.transaction_id and status = 'pending';
  return withdrawal_row;
end;
$$;

alter table public.profiles enable row level security;
alter table public.wallets enable row level security;
alter table public.vip_plans enable row level security;
alter table public.tasks enable row level security;
alter table public.task_completions enable row level security;
alter table public.transactions enable row level security;
alter table public.withdrawals enable row level security;
alter table public.referrals enable row level security;
alter table public.referral_commission_rates enable row level security;
alter table public.platform_settings enable row level security;
alter table public.announcements enable row level security;

create policy "profiles read own or admin" on public.profiles for select to authenticated
using (id = (select auth.uid()) or (select public.is_admin()));
create policy "profiles update own name" on public.profiles for update to authenticated
using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "wallets read own or admin" on public.wallets for select to authenticated
using (user_id = (select auth.uid()) or (select public.is_admin()));

create policy "vip plans readable" on public.vip_plans for select to anon, authenticated using (true);
create policy "vip plans admin manage" on public.vip_plans for all to authenticated
using ((select public.is_admin())) with check ((select public.is_admin()));

create policy "active tasks public read" on public.tasks for select to anon
using (active);
create policy "active tasks member or admin read" on public.tasks for select to authenticated
using (active or (select public.is_admin()));
create policy "tasks admin manage" on public.tasks for all to authenticated
using ((select public.is_admin())) with check ((select public.is_admin()));

create policy "task completions read own or admin" on public.task_completions for select to authenticated
using (user_id = (select auth.uid()) or (select public.is_admin()));
create policy "transactions read own or admin" on public.transactions for select to authenticated
using (user_id = (select auth.uid()) or (select public.is_admin()));

create policy "withdrawals read own or admin" on public.withdrawals for select to authenticated
using (user_id = (select auth.uid()) or (select public.is_admin()));
create policy "withdrawals admin update" on public.withdrawals for update to authenticated
using ((select public.is_admin())) with check ((select public.is_admin()));

create policy "referrals read own or admin" on public.referrals for select to authenticated
using (referrer_id = (select auth.uid()) or referred_user_id = (select auth.uid()) or (select public.is_admin()));

create policy "referral rates readable" on public.referral_commission_rates for select to authenticated
using (true);
create policy "referral rates admin manage" on public.referral_commission_rates for all to authenticated
using ((select public.is_admin())) with check ((select public.is_admin()));

create policy "platform settings admin read" on public.platform_settings for select to authenticated
using ((select public.is_admin()));
create policy "platform settings admin manage" on public.platform_settings for all to authenticated
using ((select public.is_admin())) with check ((select public.is_admin()));

create policy "announcements read active" on public.announcements for select to authenticated
using (active or (select public.is_admin()));
create policy "announcements admin manage" on public.announcements for all to authenticated
using ((select public.is_admin())) with check ((select public.is_admin()));

grant usage on schema public to anon, authenticated;
grant select on public.vip_plans, public.tasks to anon, authenticated;
grant select, update (full_name) on public.profiles to authenticated;
grant select on public.wallets, public.task_completions, public.transactions, public.withdrawals, public.referrals, public.announcements, public.referral_commission_rates to authenticated;
grant select on public.platform_settings to authenticated;
grant insert, update, delete on public.vip_plans, public.tasks, public.announcements to authenticated;
grant insert, update, delete on public.referral_commission_rates to authenticated;
grant update on public.platform_settings to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.complete_task(uuid) to authenticated;
grant execute on function public.admin_update_member(uuid, numeric, integer) to authenticated;
grant execute on function public.admin_review_withdrawal(uuid, text) to authenticated;

revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.admin_update_member(uuid, numeric, integer) from public, anon;
revoke all on function public.admin_review_withdrawal(uuid, text) from public, anon;
revoke all on function public.complete_task(uuid) from public, anon;
revoke all on function public.is_admin() from public, anon;

commit;
