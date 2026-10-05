begin;

create or replace function public.get_wallet_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  wallet_balance numeric(14, 2);
  task_earnings numeric(14, 2);
  referral_earnings numeric(14, 2);
  pending_deposits numeric(14, 2);
  pending_withdrawals numeric(14, 2);
begin
  if current_user_id is null then
    raise exception 'Sign in to view your wallet.';
  end if;

  select balance into wallet_balance
  from public.wallets
  where user_id = current_user_id;

  select coalesce(sum(reward_amount), 0) into task_earnings
  from public.task_completions
  where user_id = current_user_id;

  select coalesce(sum(earnings), 0) into referral_earnings
  from public.referrals
  where referrer_id = current_user_id;

  select coalesce(sum(amount), 0) into pending_deposits
  from public.deposits
  where user_id = current_user_id and status = 'pending';

  select coalesce(sum(amount), 0) into pending_withdrawals
  from public.withdrawals
  where user_id = current_user_id and status = 'pending';

  return pg_catalog.jsonb_build_object(
    'available_balance', coalesce(wallet_balance, 0),
    'task_earnings', task_earnings,
    'referral_earnings', referral_earnings,
    'total_earnings', task_earnings + referral_earnings,
    'pending_deposits', pending_deposits,
    'pending_withdrawals', pending_withdrawals
  );
end;
$$;

alter table public.deposits
  add column if not exists payment_submitted_at timestamptz;

create or replace function public.confirm_manual_deposit_payment(p_deposit_id uuid)
returns public.deposits
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  deposit_row public.deposits%rowtype;
begin
  if current_user_id is null then
    raise exception 'Sign in to confirm your bank transfer.';
  end if;

  select * into deposit_row
  from public.deposits
  where id = p_deposit_id and user_id = current_user_id
  for update;
  if not found then
    raise exception 'Deposit request not found.';
  end if;
  if deposit_row.status <> 'pending' then
    raise exception 'This deposit request is no longer pending.';
  end if;
  if deposit_row.expires_at <= now() then
    raise exception 'This payment request has expired.';
  end if;

  update public.deposits
  set payment_submitted_at = coalesce(payment_submitted_at, now())
  where id = p_deposit_id
  returning * into deposit_row;
  return deposit_row;
end;
$$;

create or replace function public.expire_manual_deposit(p_deposit_id uuid)
returns public.deposits
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  deposit_row public.deposits%rowtype;
begin
  if current_user_id is null then
    raise exception 'Sign in to close a deposit request.';
  end if;

  update public.deposits
  set status = 'expired', reviewed_at = now()
  where id = p_deposit_id
    and user_id = current_user_id
    and status = 'pending'
    and payment_submitted_at is null
    and expires_at <= now()
  returning * into deposit_row;

  if found then
    update public.transactions
    set status = 'expired'
    where id = deposit_row.transaction_id;
    return deposit_row;
  end if;

  select * into deposit_row
  from public.deposits
  where id = p_deposit_id and user_id = current_user_id;
  if not found then
    raise exception 'Deposit request not found.';
  end if;
  return deposit_row;
end;
$$;

create or replace function public.expire_user_manual_deposits()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  expired_count integer;
begin
  if current_user_id is null then
    raise exception 'Sign in to refresh deposit requests.';
  end if;

  with expired as (
    update public.deposits
    set status = 'expired', reviewed_at = now()
    where user_id = current_user_id
      and status = 'pending'
      and payment_submitted_at is null
      and expires_at <= now()
    returning transaction_id
  )
  update public.transactions as txn
  set status = 'expired'
  from expired
  where txn.id = expired.transaction_id;

  get diagnostics expired_count = row_count;
  return expired_count;
end;
$$;

create or replace function public.admin_expire_manual_deposits()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_count integer;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;

  with expired as (
    update public.deposits
    set status = 'expired', reviewed_at = now()
    where status = 'pending'
      and payment_submitted_at is null
      and expires_at <= now()
    returning transaction_id
  )
  update public.transactions as txn
  set status = 'expired'
  from expired
  where txn.id = expired.transaction_id;

  get diagnostics expired_count = row_count;
  return expired_count;
end;
$$;

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
  new_status text;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Invalid deposit decision.';
  end if;
  if length(coalesce(p_admin_note, '')) > 500 then
    raise exception 'Review note must be 500 characters or fewer.';
  end if;

  select * into deposit_row
  from public.deposits
  where id = p_deposit_id
  for update;
  if not found or deposit_row.status <> 'pending' then
    raise exception 'Pending deposit request not found.';
  end if;

  if deposit_row.expires_at <= now() and deposit_row.payment_submitted_at is null then
    update public.deposits
    set status = 'expired', reviewed_at = now()
    where id = p_deposit_id
    returning * into deposit_row;
    update public.transactions
    set status = 'expired'
    where id = deposit_row.transaction_id;
    return deposit_row;
  end if;

  new_status := case when p_decision = 'approved' then 'completed' else 'rejected' end;
  update public.deposits
  set status = new_status,
      admin_note = coalesce(trim(p_admin_note), ''),
      reviewed_by = (select auth.uid()),
      reviewed_at = now()
  where id = p_deposit_id
  returning * into deposit_row;

  if new_status = 'completed' then
    update public.wallets
    set balance = balance + deposit_row.amount, updated_at = now()
    where user_id = deposit_row.user_id;
    if not found then
      raise exception 'Member wallet not found.';
    end if;
  end if;

  update public.transactions
  set status = new_status,
      description = case
        when deposit_row.admin_note = '' then 'Manual deposit request ' || deposit_row.id::text
        else 'Manual deposit request ' || deposit_row.id::text || ' - ' || deposit_row.admin_note
      end
  where id = deposit_row.transaction_id;
  return deposit_row;
end;
$$;

create or replace function public.admin_manage_member(
  p_user_id uuid,
  p_full_name text,
  p_balance numeric,
  p_vip_level integer
)
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
  if nullif(trim(p_full_name), '') is null or length(trim(p_full_name)) > 160 then
    raise exception 'Enter a member name of up to 160 characters.';
  end if;
  if p_balance is null or p_balance < 0 or p_balance > 999999999999.99 then
    raise exception 'Balance must be zero or greater and within the supported limit.';
  end if;
  if p_vip_level is null or p_vip_level < 0 or p_vip_level > 9 then
    raise exception 'VIP level must be between 0 and 9.';
  end if;
  if p_vip_level > 0 and not exists (
    select 1 from public.vip_plans where level = p_vip_level
  ) then
    raise exception 'That VIP plan does not exist.';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_user_id and role = 'user'
  ) then
    raise exception 'Member account not found.';
  end if;

  select balance into old_balance
  from public.wallets
  where user_id = p_user_id
  for update;
  if not found then
    raise exception 'Member wallet not found.';
  end if;

  update public.wallets
  set balance = p_balance, updated_at = now()
  where user_id = p_user_id;

  update public.profiles
  set full_name = trim(p_full_name), vip_level = p_vip_level
  where id = p_user_id
  returning * into result_row;

  if old_balance is distinct from p_balance then
    insert into public.transactions (user_id, type, amount, status, description)
    values (
      p_user_id, 'adjustment', abs(p_balance - old_balance), 'completed',
      'Administrator updated member dashboard balance'
    );
  end if;
  return result_row;
end;
$$;

revoke all on function public.confirm_manual_deposit_payment(uuid) from public, anon;
grant execute on function public.confirm_manual_deposit_payment(uuid) to authenticated;
revoke all on function public.admin_manage_member(uuid, text, numeric, integer) from public, anon;
grant execute on function public.admin_manage_member(uuid, text, numeric, integer) to authenticated;

notify pgrst, 'reload schema';

commit;
