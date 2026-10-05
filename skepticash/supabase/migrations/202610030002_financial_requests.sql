create table if not exists public.deposits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  amount numeric(14, 2) not null check (amount >= 100),
  proof_path text not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  user_note text not null default '',
  admin_note text not null default '',
  transaction_id uuid references public.transactions (id),
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (proof_path)
);

alter table public.withdrawals
  add column if not exists admin_note text not null default '';

alter table public.withdrawals
  add column if not exists user_note text not null default '';

alter table public.withdrawals
  add column if not exists transaction_id uuid references public.transactions (id);

create index if not exists deposits_user_created_idx on public.deposits (user_id, created_at desc);
create index if not exists deposits_status_created_idx on public.deposits (status, created_at desc);

alter table public.deposits enable row level security;

create policy "deposits read own or admin" on public.deposits for select to authenticated
using (user_id = (select auth.uid()) or (select public.is_admin()));

drop function if exists public.admin_review_withdrawal(uuid, text);

drop policy if exists "deposit proofs owner upload" on storage.objects;
create policy "deposit proofs owner upload" on storage.objects for insert to authenticated
with check (
  bucket_id = 'deposit-proofs'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

drop policy if exists "deposit proofs owner or admin read" on storage.objects;
create policy "deposit proofs owner or admin read" on storage.objects for select to authenticated
using (
  bucket_id = 'deposit-proofs'
  and (
    (storage.foldername(name))[1] = (select auth.uid())::text
    or (select public.is_admin())
  )
);

drop policy if exists "deposit proofs owner cleanup" on storage.objects;
create policy "deposit proofs owner cleanup" on storage.objects for delete to authenticated
using (
  bucket_id = 'deposit-proofs'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and not exists (
    select 1 from public.deposits as requests
    where requests.proof_path = name
  )
);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('deposit-proofs', 'deposit-proofs', false, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update
set public = false, file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'];

create or replace function public.submit_deposit(
  p_amount numeric,
  p_proof_path text,
  p_user_note text default ''
)
returns public.deposits
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  deposit_row public.deposits%rowtype;
  transaction_row public.transactions%rowtype;
begin
  if current_user_id is null then
    raise exception 'Sign in to submit a deposit request.';
  end if;
  if p_amount is null or p_amount < 100 or p_amount > 999999999999.99 or p_amount <> round(p_amount, 2) then
    raise exception 'Enter a deposit amount of at least ₦100.';
  end if;
  if p_proof_path is null
    or p_proof_path !~ ('^' || current_user_id::text || '/[0-9a-fA-F-]{36}/[^/]+$')
    or length(p_proof_path) > 500 then
    raise exception 'Upload a valid payment receipt before submitting.';
  end if;
  if length(coalesce(p_user_note, '')) > 500 then
    raise exception 'Deposit note must be 500 characters or fewer.';
  end if;
  perform 1 from storage.objects
  where bucket_id = 'deposit-proofs' and name = p_proof_path
  for key share;
  if not found then
    raise exception 'The uploaded receipt could not be found.';
  end if;

  select * into deposit_row
  from public.deposits
  where user_id = current_user_id and proof_path = p_proof_path;
  if found then
    return deposit_row;
  end if;

  insert into public.transactions (user_id, type, amount, status, description)
  values (current_user_id, 'deposit', p_amount, 'pending', 'Deposit request')
  returning * into transaction_row;

  insert into public.deposits (user_id, amount, proof_path, user_note, transaction_id)
  values (current_user_id, p_amount, p_proof_path, coalesce(trim(p_user_note), ''), transaction_row.id)
  returning * into deposit_row;

  update public.transactions
  set description = 'Deposit request ' || deposit_row.id::text
  where id = transaction_row.id;
  return deposit_row;
end;
$$;

create or replace function public.request_withdrawal(
  p_amount numeric,
  p_bank_name text,
  p_account_last4 text,
  p_user_note text default ''
)
returns public.withdrawals
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  transaction_row public.transactions%rowtype;
  withdrawal_row public.withdrawals%rowtype;
begin
  if current_user_id is null then
    raise exception 'Sign in to request a withdrawal.';
  end if;
  if p_amount is null or p_amount < 100 or p_amount > 999999999999.99
    or p_amount <> trunc(p_amount, 2) then
    raise exception 'Enter a withdrawal amount of at least ₦100, with at most two decimal places.';
  end if;
  if nullif(trim(p_bank_name), '') is null or length(p_bank_name) > 100
    or p_account_last4 is null or p_account_last4 !~ '^[0-9]{4}$' then
    raise exception 'Enter the bank name and last four digits of the account.';
  end if;
  if length(coalesce(p_user_note, '')) > 500 then
    raise exception 'Withdrawal note must be 500 characters or fewer.';
  end if;

  update public.wallets
  set balance = balance - p_amount, updated_at = now()
  where user_id = current_user_id and balance >= p_amount;
  if not found then
    raise exception 'Your available balance is too low for this withdrawal.';
  end if;

  insert into public.transactions (user_id, type, amount, status, description)
  values (current_user_id, 'withdrawal', p_amount, 'pending', 'Withdrawal request')
  returning * into transaction_row;

  insert into public.withdrawals (user_id, amount, bank_name, account_last4, user_note, transaction_id)
  values (current_user_id, p_amount, trim(p_bank_name), p_account_last4, coalesce(trim(p_user_note), ''), transaction_row.id)
  returning * into withdrawal_row;

  update public.transactions
  set description = 'Withdrawal request ' || withdrawal_row.id::text
  where id = transaction_row.id;
  return withdrawal_row;
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

  update public.deposits
  set status = p_decision,
      admin_note = coalesce(trim(p_admin_note), ''),
      reviewed_by = (select auth.uid()),
      reviewed_at = now()
  where id = p_deposit_id and status = 'pending'
  returning * into deposit_row;
  if not found then
    raise exception 'Pending deposit request not found.';
  end if;

  if p_decision = 'approved' then
    update public.wallets
    set balance = balance + deposit_row.amount, updated_at = now()
    where user_id = deposit_row.user_id;
    if not found then
      raise exception 'Member wallet not found.';
    end if;
  end if;

  update public.transactions
  set status = p_decision,
      description = case
        when deposit_row.admin_note = '' then 'Deposit request ' || deposit_row.id::text
        else 'Deposit request ' || deposit_row.id::text || ' — ' || deposit_row.admin_note
      end
  where id = deposit_row.transaction_id;
  return deposit_row;
end;
$$;

create or replace function public.admin_review_withdrawal(
  p_withdrawal_id uuid,
  p_decision text,
  p_admin_note text default ''
)
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
  if length(coalesce(p_admin_note, '')) > 500 then
    raise exception 'Review note must be 500 characters or fewer.';
  end if;

  update public.withdrawals
  set status = p_decision,
      admin_note = coalesce(trim(p_admin_note), ''),
      reviewed_by = (select auth.uid()),
      reviewed_at = now()
  where id = p_withdrawal_id and status = 'pending'
  returning * into withdrawal_row;
  if not found then
    raise exception 'Pending withdrawal not found.';
  end if;

  if p_decision = 'rejected' then
    update public.wallets
    set balance = balance + withdrawal_row.amount, updated_at = now()
    where user_id = withdrawal_row.user_id;
    if not found then
      raise exception 'Member wallet not found.';
    end if;
  end if;

  update public.transactions
  set status = p_decision,
      description = case
        when withdrawal_row.admin_note = '' then 'Withdrawal request ' || withdrawal_row.id::text
        else 'Withdrawal request ' || withdrawal_row.id::text || ' — ' || withdrawal_row.admin_note
      end
  where id = withdrawal_row.transaction_id;
  return withdrawal_row;
end;
$$;

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
  from public.wallets where user_id = current_user_id;

  select coalesce(sum(amount), 0) into task_earnings
  from public.task_completions where user_id = current_user_id;

  select coalesce(sum(earnings), 0) into referral_earnings
  from public.referrals where referrer_id = current_user_id;

  select coalesce(sum(amount), 0) into pending_deposits
  from public.deposits where user_id = current_user_id and status = 'pending';

  select coalesce(sum(amount), 0) into pending_withdrawals
  from public.withdrawals where user_id = current_user_id and status = 'pending';

  return jsonb_build_object(
    'available_balance', coalesce(wallet_balance, 0),
    'task_earnings', task_earnings,
    'referral_earnings', referral_earnings,
    'total_earnings', task_earnings + referral_earnings,
    'pending_deposits', pending_deposits,
    'pending_withdrawals', pending_withdrawals
  );
end;
$$;

revoke all on public.deposits from anon, authenticated;
grant select on public.deposits to authenticated;
grant execute on function public.submit_deposit(numeric, text, text) to authenticated;
grant execute on function public.request_withdrawal(numeric, text, text, text) to authenticated;
grant execute on function public.admin_review_deposit(uuid, text, text) to authenticated;
grant execute on function public.admin_review_withdrawal(uuid, text, text) to authenticated;
grant execute on function public.get_wallet_summary() to authenticated;

revoke all on function public.submit_deposit(numeric, text, text) from public, anon;
revoke all on function public.request_withdrawal(numeric, text, text, text) from public, anon;
revoke all on function public.admin_review_deposit(uuid, text, text) from public, anon;
revoke all on function public.admin_review_withdrawal(uuid, text, text) from public, anon;
revoke all on function public.get_wallet_summary() from public, anon;

notify pgrst, 'reload schema';
