begin;

do $$
declare
  foreign_key record;
begin
  for foreign_key in
    select constraint_row.conname
    from pg_constraint as constraint_row
    where constraint_row.conrelid = 'public.profiles'::regclass
      and constraint_row.confrelid = 'auth.users'::regclass
      and constraint_row.contype = 'f'
  loop
    execute format('alter table public.profiles drop constraint %I', foreign_key.conname);
  end loop;
end;
$$;   
 
delete from auth.sessions as auth_session
using public.profiles as profile
where auth_session.user_id = profile.id
  and profile.role = 'user';

create table if not exists public.member_credentials (
  id uuid primary key references public.profiles (id) on delete cascade,
  password_hash text not null,
  must_change_password boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint member_credentials_hash_format check (password_hash like 'scrypt$16384$8$1$%')
);

alter table public.member_credentials
  add column if not exists must_change_password boolean not null default false;

create table if not exists public.member_sessions (
  token_hash text primary key check (token_hash ~ '^[a-f0-9]{64}$'),
  user_id uuid not null references public.profiles (id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index if not exists member_sessions_user_id_idx on public.member_sessions (user_id);
create index if not exists member_sessions_expiry_idx on public.member_sessions (expires_at);

create table if not exists public.member_auth_attempts (
  attempt_key text primary key check (attempt_key ~ '^[a-f0-9]{64}$'),
  attempt_count integer not null default 0,
  window_started_at timestamptz not null default now()
);

alter table public.member_credentials enable row level security;
alter table public.member_sessions enable row level security;
alter table public.member_auth_attempts enable row level security;

revoke all on public.member_credentials, public.member_sessions, public.member_auth_attempts
  from public, anon, authenticated;
grant all on public.member_credentials, public.member_sessions, public.member_auth_attempts
  to service_role;

create or replace function public.create_custom_member_account(
  p_phone text,
  p_referral_code text,
  p_password_hash text
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  referral_code_value text := upper(trim(coalesce(p_referral_code, '')));
  referrer_id uuid;
  ancestor_id uuid;
  referral_level integer;
  commission numeric(5, 2);
  default_starting_balance numeric(14, 2);
  default_vip_level integer;
  profile_row public.profiles%rowtype;
begin
  if p_phone is null or p_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'Enter a valid phone number in international format.';
  end if;
  if p_password_hash is null or p_password_hash !~ '^scrypt\$16384\$8\$1\$[a-f0-9]{32}\$[a-f0-9]{128}$' then
    raise exception 'Password credential was not generated securely.';
  end if;
  if referral_code_value <> '' then
    select id into referrer_id
    from public.profiles
    where referral_code = referral_code_value
      and role = 'user';
    if referrer_id is null then
      raise exception 'That referral code is not valid.';
    end if;
  end if;

  select coalesce((select (value #>> '{}')::numeric
                   from public.platform_settings
                   where key = 'default_starting_balance'), 0)
    into default_starting_balance;
  select coalesce((select (value #>> '{}')::integer
                   from public.platform_settings
                   where key = 'default_vip_level'), 0)
    into default_vip_level;

  insert into public.profiles (id, email, phone, full_name, role, referred_by, vip_level)
  values (gen_random_uuid(), '', p_phone, '', 'user', referrer_id, default_vip_level)
  returning * into profile_row;

  insert into public.member_credentials (id, password_hash)
  values (profile_row.id, p_password_hash);
  insert into public.wallets (user_id, balance)
  values (profile_row.id, default_starting_balance);

  if default_starting_balance > 0 then
    insert into public.transactions (user_id, type, amount, status, description)
    values (
      profile_row.id, 'adjustment', default_starting_balance,
      'completed', 'Default signup balance'
    );
  end if;

  if referrer_id is not null then
    ancestor_id := referrer_id;
    for referral_level in 1..3 loop
      if ancestor_id is null then
        exit;
      end if;
      select commission_percent into commission
      from public.referral_commission_rates
      where level = referral_level;
      insert into public.referrals (referrer_id, referred_user_id, level, commission_percent)
      values (ancestor_id, profile_row.id, referral_level, coalesce(commission, 0));
      select referred_by into ancestor_id
      from public.profiles
      where id = ancestor_id;
    end loop;
  end if;

  return profile_row;
end;
$$;

revoke all on function public.create_custom_member_account(text, text, text)
  from public, anon, authenticated;
grant execute on function public.create_custom_member_account(text, text, text)
  to service_role;

create or replace function public.check_member_auth_rate_limit(p_attempt_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_count integer;
begin
  if p_attempt_key is null or p_attempt_key !~ '^[a-f0-9]{64}$' then
    raise exception 'Invalid authentication request.';
  end if;

  insert into public.member_auth_attempts (attempt_key, attempt_count, window_started_at)
  values (p_attempt_key, 1, now())
  on conflict (attempt_key) do update
  set attempt_count = case
        when public.member_auth_attempts.window_started_at < now() - interval '15 minutes' then 1
        else public.member_auth_attempts.attempt_count + 1
      end,
      window_started_at = case
        when public.member_auth_attempts.window_started_at < now() - interval '15 minutes' then now()
        else public.member_auth_attempts.window_started_at
      end
  returning attempt_count into current_count;

  if current_count > 10 then
    raise exception 'Too many authentication attempts. Try again in 15 minutes.';
  end if;

  delete from public.member_auth_attempts
  where window_started_at < now() - interval '1 day';
end;
$$;

create or replace function public.clear_member_auth_rate_limit(p_attempt_key text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.member_auth_attempts where attempt_key = p_attempt_key;
$$;

revoke all on function public.check_member_auth_rate_limit(text)
  from public, anon, authenticated;
revoke all on function public.clear_member_auth_rate_limit(text)
  from public, anon, authenticated;
grant execute on function public.check_member_auth_rate_limit(text)
  to service_role;
grant execute on function public.clear_member_auth_rate_limit(text)
  to service_role;

create or replace function public.create_manual_deposit(
  p_full_name text,
  p_phone text,
  p_amount numeric
)
returns public.deposits
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  registered_phone text;
  deposit_row public.deposits%rowtype;
  transaction_row public.transactions%rowtype;
begin
  if current_user_id is null then
    raise exception 'Sign in to create a deposit request.';
  end if;
  if nullif(trim(p_full_name), '') is null or length(trim(p_full_name)) > 160 then
    raise exception 'Enter your full name (up to 160 characters).';
  end if;
  select phone into registered_phone from public.profiles where id = current_user_id;
  if registered_phone is null or trim(p_phone) <> registered_phone then
    raise exception 'Use the phone number registered to your signed-in account.';
  end if;
  if p_amount is null or p_amount < 100 or p_amount > 999999999999.99
     or p_amount <> round(p_amount, 2) then
    raise exception 'Enter a deposit amount of at least ₦100.';
  end if;
  perform public.get_manual_deposit_details();

  insert into public.transactions (user_id, type, amount, status, description)
  values (current_user_id, 'deposit', p_amount, 'pending', 'Deposit request')
  returning * into transaction_row;

  insert into public.deposits (
    user_id, full_name, email, phone, amount, status, transaction_id, expires_at
  )
  values (
    current_user_id, trim(p_full_name), '', registered_phone, p_amount,
    'pending', transaction_row.id, now() + interval '25 minutes'
  )
  returning * into deposit_row;

  update public.transactions
  set description = 'Deposit request ' || deposit_row.id::text
  where id = transaction_row.id;
  return deposit_row;
end;
$$;

drop function if exists public.create_vip_payment_request(integer, text, text);
create function public.create_vip_payment_request(
  p_plan_level integer,
  p_full_name text,
  p_phone text
)
returns public.vip_payment_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  registered_phone text;
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
  select phone into registered_phone from public.profiles where id = current_user_id;
  if registered_phone is null or trim(p_phone) <> registered_phone then
    raise exception 'Use the phone number registered to your signed-in account.';
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

  select * into selected_plan from public.vip_plans where level = p_plan_level;
  if not found or selected_plan.upgrade_cost <= 0 then
    raise exception 'That VIP plan does not have a payable price configured.';
  end if;
  perform public.get_manual_deposit_details();

  insert into public.vip_payment_requests (
    user_id, plan_level, full_name, email, phone, amount, status, expires_at
  )
  values (
    current_user_id, selected_plan.level, trim(p_full_name), '',
    registered_phone, selected_plan.upgrade_cost, 'pending', now() + interval '25 minutes'
  )
  returning * into request_row;

  insert into public.transactions (user_id, type, amount, status, description)
  values (
    current_user_id, 'vip_purchase', request_row.amount, 'pending',
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

revoke all on function public.create_manual_deposit(text, text, numeric)
  from public, anon;
grant execute on function public.create_manual_deposit(text, text, numeric)
  to authenticated;
revoke all on function public.create_vip_payment_request(integer, text, text)
  from public, anon;
grant execute on function public.create_vip_payment_request(integer, text, text)
  to authenticated;

notify pgrst, 'reload schema';

commit;
