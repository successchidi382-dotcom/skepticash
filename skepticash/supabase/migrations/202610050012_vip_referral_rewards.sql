begin;

create table if not exists public.vip_referral_reward_rates (
  level integer primary key references public.vip_plans (level) on delete cascade,
  reward_amount numeric(14, 2) not null default 0 check (reward_amount >= 0),
  updated_at timestamptz not null default now()
);

insert into public.vip_referral_reward_rates (level, reward_amount)
select level, 0
from public.vip_plans
on conflict (level) do nothing;

create table if not exists public.vip_referral_rewards (
  id uuid primary key default gen_random_uuid(),
  vip_payment_request_id uuid not null unique references public.vip_payment_requests (id),
  referrer_id uuid not null references public.profiles (id),
  referred_user_id uuid not null references public.profiles (id),
  plan_level integer not null references public.vip_plans (level),
  amount numeric(14, 2) not null check (amount >= 0),
  paid_at timestamptz not null default now(),
  unique (referred_user_id, plan_level)
);

alter table public.vip_referral_reward_rates enable row level security;
alter table public.vip_referral_rewards enable row level security;

drop policy if exists "vip referral rates readable" on public.vip_referral_reward_rates;
create policy "vip referral rates readable" on public.vip_referral_reward_rates
for select to authenticated using (true);

drop policy if exists "vip referral rates admin manage" on public.vip_referral_reward_rates;
create policy "vip referral rates admin manage" on public.vip_referral_reward_rates
for all to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

drop policy if exists "vip referral rewards admin read" on public.vip_referral_rewards;
create policy "vip referral rewards admin read" on public.vip_referral_rewards
for select to authenticated using ((select public.is_admin()));

grant select on public.vip_referral_reward_rates, public.vip_referral_rewards to authenticated;

create or replace function public.admin_save_vip_referral_rewards(p_rewards jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  reward_row record;
  submitted_count integer;
  distinct_count integer;
  valid_count integer;
  saved_count integer := 0;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;
  if jsonb_typeof(p_rewards) <> 'array' then
    raise exception 'VIP referral rewards must be submitted as a list.';
  end if;

  select count(*), count(distinct submitted.level),
         count(*) filter (where plan.level is not null)
  into submitted_count, distinct_count, valid_count
  from jsonb_to_recordset(p_rewards) as submitted(level integer, amount numeric)
  left join public.vip_plans as plan on plan.level = submitted.level;

  if submitted_count <> (select count(*) from public.vip_plans)
     or distinct_count <> submitted_count or valid_count <> submitted_count then
    raise exception 'Submit exactly one reward for every VIP level.';
  end if;

  for reward_row in
    select submitted.level, submitted.amount
    from jsonb_to_recordset(p_rewards) as submitted(level integer, amount numeric)
  loop
    if reward_row.amount is null or reward_row.amount < 0
       or reward_row.amount > 999999999999.99
       or reward_row.amount <> round(reward_row.amount, 2) then
      raise exception 'Enter a valid reward amount for VIP %.', reward_row.level;
    end if;

    insert into public.vip_referral_reward_rates (level, reward_amount, updated_at)
    values (reward_row.level, reward_row.amount, now())
    on conflict (level) do update
      set reward_amount = excluded.reward_amount,
          updated_at = now();
    saved_count := saved_count + 1;
  end loop;
  return saved_count;
end;
$$;

revoke all on function public.admin_save_vip_referral_rewards(jsonb) from public, anon;
grant execute on function public.admin_save_vip_referral_rewards(jsonb) to authenticated;

create or replace function public.admin_update_referral_reward(p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'First-deposit referral rewards are no longer supported. Configure VIP referral rewards instead.';
end;
$$;

revoke all on function public.admin_update_referral_reward(numeric) from public, anon, authenticated;
revoke all on function public.get_referral_reward_amount() from public, anon, authenticated;

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

  return deposit_row;
end;
$$;

revoke all on function public.admin_review_deposit(uuid, text, text) from public, anon;
grant execute on function public.admin_review_deposit(uuid, text, text) to authenticated;

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
  v_referrer_id uuid;
  v_reward_amount numeric(14, 2);
  inserted_reward_id uuid;
  referred_phone text;
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
    select vip_level, referred_by
      into current_vip_level, v_referrer_id
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

  if p_decision = 'approved' and v_referrer_id is not null then
    select rate.reward_amount into v_reward_amount
    from public.vip_referral_reward_rates as rate
    where rate.level = request_row.plan_level;
    v_reward_amount := coalesce(v_reward_amount, 0);

    insert into public.vip_referral_rewards (
      vip_payment_request_id, referrer_id, referred_user_id, plan_level, amount
    )
    values (
      request_row.id, v_referrer_id, request_row.user_id, request_row.plan_level, v_reward_amount
    )
    on conflict do nothing
    returning id into inserted_reward_id;

    if inserted_reward_id is not null and v_reward_amount > 0 then
      update public.wallets
      set balance = balance + v_reward_amount, updated_at = now()
      where user_id = v_referrer_id;
      if not found then
        raise exception 'Referrer wallet not found.';
      end if;

      update public.referrals
      set earnings = earnings + v_reward_amount
      where public.referrals.referrer_id = v_referrer_id
        and public.referrals.referred_user_id = request_row.user_id
        and level = 1;

      select phone into referred_phone
      from public.profiles
      where id = request_row.user_id;
      insert into public.transactions (user_id, type, amount, status, description)
      values (
        v_referrer_id,
        'adjustment',
        v_reward_amount,
        'completed',
        'VIP ' || request_row.plan_level::text || ' referral reward for ' ||
          coalesce(referred_phone, 'a referred member')
      );
    end if;
  end if;

  return request_row;
end;
$$;

revoke all on function public.admin_review_vip_payment(uuid, text, text) from public, anon;
grant execute on function public.admin_review_vip_payment(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';

commit;
