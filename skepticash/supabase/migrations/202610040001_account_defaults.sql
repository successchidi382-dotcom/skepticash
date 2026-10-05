begin;

alter table public.profiles
  add column if not exists vip_level_customized boolean not null default false;

alter table public.wallets
  add column if not exists balance_customized boolean not null default false;

insert into public.platform_settings (key, value)
values
  ('default_starting_balance', '0'::jsonb),
  ('default_vip_level', '0'::jsonb)
on conflict (key) do nothing;

update public.profiles
set vip_level_customized = true 
where vip_level <> 0;

update public.wallets as wallet
set balance_customized = true
where wallet.balance <> 0
   or exists (
     select 1 from public.transactions as txn
     where txn.user_id = wallet.user_id
   )
   or exists (
     select 1 from public.deposits as deposit
     where deposit.user_id = wallet.user_id
   )
   or exists (
     select 1 from public.withdrawals as withdrawal
     where withdrawal.user_id = wallet.user_id
   );

create or replace function public.track_wallet_balance_customization()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.balance is distinct from old.balance
     and pg_catalog.current_setting('skepticash.apply_account_defaults', true) is distinct from 'on' then
    new.balance_customized := true;
  end if;
  return new;
end;
$$;

create or replace function public.track_vip_level_customization()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.vip_level is distinct from old.vip_level
     and pg_catalog.current_setting('skepticash.apply_account_defaults', true) is distinct from 'on' then
    new.vip_level_customized := true;
  end if;
  return new;
end;
$$;

create or replace function public.mark_wallet_customized_for_request()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update public.wallets
  set balance_customized = true
  where user_id = new.user_id;
  return new;
end;
$$;

drop trigger if exists track_wallet_balance_customization on public.wallets;
create trigger track_wallet_balance_customization
  before update of balance on public.wallets
  for each row execute function public.track_wallet_balance_customization();

drop trigger if exists track_vip_level_customization on public.profiles;
create trigger track_vip_level_customization
  before update of vip_level on public.profiles
  for each row execute function public.track_vip_level_customization();

drop trigger if exists mark_deposit_wallet_customized on public.deposits;
create trigger mark_deposit_wallet_customized
  after insert on public.deposits
  for each row execute function public.mark_wallet_customized_for_request();

drop trigger if exists mark_withdrawal_wallet_customized on public.withdrawals;
create trigger mark_withdrawal_wallet_customized
  after insert on public.withdrawals
  for each row execute function public.mark_wallet_customized_for_request();

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
  default_starting_balance numeric(14, 2);
  default_vip_level integer;
begin
  select id into referrer_id
  from public.profiles
  where referral_code = upper(coalesce(new.raw_user_meta_data ->> 'referral_code', ''))
    and id <> new.id;

  select coalesce((select (value #>> '{}')::numeric
                   from public.platform_settings
                   where key = 'default_starting_balance'), 0)
    into default_starting_balance;
  select coalesce((select (value #>> '{}')::integer
                   from public.platform_settings
                   where key = 'default_vip_level'), 0)
    into default_vip_level;

  insert into public.profiles (id, email, full_name, referred_by, vip_level)
  values (
    new.id,
    coalesce(new.email, ''),
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
  update public.wallets
  set balance = p_balance, updated_at = now()
  where user_id = p_user_id;
  update public.profiles
  set vip_level = p_vip_level
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

create or replace function public.admin_update_account_defaults(
  p_starting_balance numeric,
  p_vip_level integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_wallets integer;
  changed_profiles integer;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;
  if p_starting_balance is null or p_starting_balance < 0 or p_starting_balance > 999999999999.99 then
    raise exception 'Default balance must be zero or greater and within the supported limit.';
  end if;
  if p_vip_level is null or p_vip_level < 0 or p_vip_level > 9 then
    raise exception 'Default VIP level must be between 0 and 9.';
  end if;
  if p_vip_level > 0 and not exists (select 1 from public.vip_plans where level = p_vip_level) then
    raise exception 'That default VIP plan does not exist.';
  end if;

  insert into public.platform_settings (key, value)
  values
    ('default_starting_balance', to_jsonb(p_starting_balance)),
    ('default_vip_level', to_jsonb(p_vip_level))
  on conflict (key) do update
    set value = excluded.value, updated_at = now();

  perform pg_catalog.set_config('skepticash.apply_account_defaults', 'on', true);

  with candidates as materialized (
    select user_id, balance as old_balance
    from public.wallets
    where not balance_customized and balance is distinct from p_starting_balance
    for update
  ), changed as (
    update public.wallets as wallet
    set balance = p_starting_balance, updated_at = now()
    from candidates
    where wallet.user_id = candidates.user_id
    returning wallet.user_id, candidates.old_balance, wallet.balance as new_balance
  )
  insert into public.transactions (user_id, type, amount, status, description)
  select user_id, 'adjustment', abs(new_balance - old_balance), 'completed',
         pg_catalog.format('Default balance updated from %s to %s', old_balance, new_balance)
  from changed;

  get diagnostics changed_wallets = row_count;

  update public.profiles
  set vip_level = p_vip_level
  where not vip_level_customized and vip_level is distinct from p_vip_level;
  get diagnostics changed_profiles = row_count;

  return pg_catalog.jsonb_build_object(
    'starting_balance', p_starting_balance,
    'vip_level', p_vip_level,
    'wallets_updated', changed_wallets,
    'profiles_updated', changed_profiles
  );
end;
$$;

revoke all on function public.track_wallet_balance_customization() from public, anon, authenticated;
revoke all on function public.track_vip_level_customization() from public, anon, authenticated;
revoke all on function public.mark_wallet_customized_for_request() from public, anon, authenticated;
revoke all on function public.admin_update_account_defaults(numeric, integer) from public, anon;
grant execute on function public.admin_update_account_defaults(numeric, integer) to authenticated;

commit;
