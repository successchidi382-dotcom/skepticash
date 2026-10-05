begin;

alter table public.profiles
  add column if not exists phone text;

update public.profiles as profile
set phone = auth_user.phone
from auth.users as auth_user
where auth_user.id = profile.id 
  and profile.phone is null
  and auth_user.phone is not null;

create unique index if not exists profiles_phone_unique_idx
  on public.profiles (phone)
  where phone is not null and phone <> '';

alter table public.deposits
  add column if not exists phone text not null default '';

update public.deposits as deposit
set phone = profile.phone
from public.profiles as profile
where profile.id = deposit.user_id
  and deposit.phone = ''
  and profile.phone is not null;

alter table public.vip_payment_requests
  add column if not exists phone text not null default '';

update public.vip_payment_requests as request
set phone = profile.phone
from public.profiles as profile
where profile.id = request.user_id
  and request.phone = ''
  and profile.phone is not null;

alter table public.referrals
  add column if not exists reward_amount numeric(14, 2) not null default 0
    check (reward_amount >= 0),
  add column if not exists reward_paid_at timestamptz;

insert into public.platform_settings (key, value)
values ('referral_reward_amount', '0'::jsonb)
on conflict (key) do nothing;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  referrer_id uuid;
  submitted_referral_code text;
  ancestor_id uuid;
  referral_level integer;
  commission numeric(5, 2);
  default_starting_balance numeric(14, 2);
  default_vip_level integer;
begin
  submitted_referral_code := upper(trim(coalesce(new.raw_user_meta_data ->> 'referral_code', '')));
  select id into referrer_id
  from public.profiles
  where referral_code = submitted_referral_code
    and id <> new.id;
  if submitted_referral_code <> '' and referrer_id is null then
    raise exception 'That referral code is not valid.';
  end if;

  select coalesce((select (value #>> '{}')::numeric
                   from public.platform_settings
                   where key = 'default_starting_balance'), 0)
    into default_starting_balance;
  select coalesce((select (value #>> '{}')::integer
                   from public.platform_settings
                   where key = 'default_vip_level'), 0)
    into default_vip_level;

  insert into public.profiles (id, email, phone, full_name, referred_by, vip_level)
  values (
    new.id,
    coalesce(new.email, ''),
    nullif(new.phone, ''),
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    referrer_id,
    default_vip_level
  );
  insert into public.wallets (user_id, balance)
  values (new.id, default_starting_balance);

  if default_starting_balance > 0 then
    insert into public.transactions (user_id, type, amount, status, description)
    values (new.id, 'adjustment', default_starting_balance, 'completed', 'Default signup balance');
  end if;

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

drop function if exists public.create_manual_deposit(text, text, numeric);
create function public.create_manual_deposit(
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
  select phone into registered_phone from auth.users where id = current_user_id;
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
    current_user_id, trim(p_full_name), '', registered_phone, p_amount, 'pending',
    transaction_row.id, now() + interval '25 minutes'
  )
  returning * into deposit_row;

  update public.transactions
  set description = 'Deposit request ' || deposit_row.id::text
  where id = transaction_row.id;
  return deposit_row;
end;
$$;

revoke all on function public.create_manual_deposit(text, text, numeric) from public, anon;
grant execute on function public.create_manual_deposit(text, text, numeric) to authenticated;

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
  select phone into registered_phone from auth.users where id = current_user_id;
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
    current_user_id, selected_plan.level, trim(p_full_name), '', registered_phone,
    selected_plan.upgrade_cost, 'pending', now() + interval '25 minutes'
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

revoke all on function public.create_vip_payment_request(integer, text, text) from public, anon;
grant execute on function public.create_vip_payment_request(integer, text, text) to authenticated;

create or replace function public.admin_update_referral_reward(p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  referral_row record;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;
  if p_amount is null or p_amount < 0 or p_amount > 999999999999.99
     or p_amount <> round(p_amount, 2) then
    raise exception 'Enter a referral reward amount between ₦0 and ₦999,999,999,999.99.';
  end if;
  insert into public.platform_settings (key, value)
  values ('referral_reward_amount', to_jsonb(p_amount))
  on conflict (key) do update
    set value = excluded.value, updated_at = now();
  if p_amount > 0 then
    for referral_row in
      update public.referrals as referral
      set reward_amount = p_amount,
          reward_paid_at = now()
      where referral.level = 1
        and referral.reward_paid_at is null
        and exists (
          select 1 from public.deposits as deposit
          where deposit.user_id = referral.referred_user_id
            and deposit.status in ('approved', 'completed')
        )
      returning referral.referrer_id, referral.referred_user_id
    loop
      update public.wallets
      set balance = balance + p_amount, updated_at = now()
      where user_id = referral_row.referrer_id;
      if not found then
        raise exception 'Referrer wallet not found.';
      end if;
      update public.referrals
      set earnings = earnings + p_amount
      where referrer_id = referral_row.referrer_id
        and referred_user_id = referral_row.referred_user_id
        and level = 1;
      insert into public.transactions (user_id, type, amount, status, description)
      values (
        referral_row.referrer_id,
        'adjustment',
        p_amount,
        'completed',
        'Referral reward for first approved deposit from ' || coalesce(
          (select phone from public.profiles where id = referral_row.referred_user_id),
          'a referred member'
        )
      );
    end loop;
  end if;
  return pg_catalog.jsonb_build_object('amount', p_amount);
end;
$$;

revoke all on function public.admin_update_referral_reward(numeric) from public, anon;
grant execute on function public.admin_update_referral_reward(numeric) to authenticated;

create or replace function public.get_referral_reward_amount()
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  reward numeric(14, 2);
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in to view referral information.';
  end if;
  select coalesce((value #>> '{}')::numeric, 0)
  into reward
  from public.platform_settings
  where key = 'referral_reward_amount';
  return coalesce(reward, 0);
end;
$$;

revoke all on function public.get_referral_reward_amount() from public, anon;
grant execute on function public.get_referral_reward_amount() to authenticated;

create or replace function public.admin_review_deposit(
  p_deposit_id uuid,
  p_decision text,
  p_admin_note text default ''
)
returns public.deposits
language plpgsql
security definer
set search_path = ''
as $$
declare
  deposit_row public.deposits%rowtype;
  was_credited boolean;
  should_credit boolean;
  new_status text;
  is_first_approved_deposit boolean;
  configured_referral_reward numeric(14, 2);
  referrer_id uuid;
  paid_reward numeric(14, 2);
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;
  if p_decision not in ('approved', 'rejected', 'restore') then
    raise exception 'Invalid deposit decision.';
  end if;
  if length(coalesce(p_admin_note, '')) > 500 then
    raise exception 'Review note must be 500 characters or fewer.';
  end if;

  select * into deposit_row
  from public.deposits where id = p_deposit_id for update;
  if not found then
    raise exception 'Deposit request not found.';
  end if;

  if p_decision = 'restore' then
    if deposit_row.status <> 'rejected' then
      raise exception 'Only rejected deposits can be restored.';
    end if;
    update public.deposits
    set status = 'pending', expires_at = now() + interval '25 minutes',
        admin_note = '', reviewed_by = null, reviewed_at = null
    where id = p_deposit_id returning * into deposit_row;
    update public.transactions
    set status = 'pending', description = 'Restored deposit request ' || deposit_row.id::text
    where id = deposit_row.transaction_id;
    return deposit_row;
  end if;

  perform 1 from public.profiles where id = deposit_row.user_id for update;
  select exists (
    select 1 from public.deposits
    where user_id = deposit_row.user_id
      and id <> deposit_row.id
      and status in ('approved', 'completed')
  ) into is_first_approved_deposit;
  is_first_approved_deposit := not is_first_approved_deposit;

  was_credited := deposit_row.status in ('approved', 'completed');
  should_credit := p_decision = 'approved';
  new_status := case when should_credit then 'completed' else 'rejected' end;
  if was_credited is distinct from should_credit then
    if should_credit then
      update public.wallets set balance = balance + deposit_row.amount, updated_at = now()
      where user_id = deposit_row.user_id;
      if not found then raise exception 'Member wallet not found.'; end if;
    else
      update public.wallets set balance = balance - deposit_row.amount, updated_at = now()
      where user_id = deposit_row.user_id and balance >= deposit_row.amount;
      if not found then
        raise exception 'Member wallet does not have enough balance to reverse this deposit.';
      end if;
    end if;
  end if;

  update public.deposits
  set status = new_status, admin_note = coalesce(trim(p_admin_note), ''),
      reviewed_by = (select auth.uid()), reviewed_at = now()
  where id = p_deposit_id returning * into deposit_row;

  update public.transactions
  set status = new_status,
      description = case
        when deposit_row.admin_note = '' then 'Deposit request ' || deposit_row.id::text
        else 'Deposit request ' || deposit_row.id::text || ' - ' || deposit_row.admin_note
      end
  where id = deposit_row.transaction_id;

  if should_credit and is_first_approved_deposit then
    select coalesce((value #>> '{}')::numeric, 0)
    into configured_referral_reward
    from public.platform_settings
    where key = 'referral_reward_amount';

    if coalesce(configured_referral_reward, 0) > 0 then
      update public.referrals
      set reward_amount = configured_referral_reward,
          reward_paid_at = now()
      where referred_user_id = deposit_row.user_id
        and level = 1
        and reward_paid_at is null
      returning referrer_id, reward_amount into referrer_id, paid_reward;
    end if;

    if found and coalesce(paid_reward, 0) > 0 then
      update public.referrals
      set earnings = earnings + paid_reward
      where referred_user_id = deposit_row.user_id and level = 1;
      update public.wallets
      set balance = balance + paid_reward, updated_at = now()
      where user_id = referrer_id;
      if not found then raise exception 'Referrer wallet not found.'; end if;
      insert into public.transactions (user_id, type, amount, status, description)
      values (
        referrer_id, 'adjustment', paid_reward, 'completed',
        'Referral reward for first approved deposit from ' || coalesce(
          (select phone from public.profiles where id = deposit_row.user_id), 'a referred member'
        )
      );
    end if;
  end if;

  return deposit_row;
end;
$$;

revoke all on function public.admin_review_deposit(uuid, text, text) from public, anon;
grant execute on function public.admin_review_deposit(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';

commit;
