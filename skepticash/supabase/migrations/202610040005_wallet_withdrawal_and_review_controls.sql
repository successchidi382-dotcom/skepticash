begin;

alter table public.withdrawals
  add column if not exists account_name text not null default '',
  add column if not exists account_number text not null default '';

update public.withdrawals
set account_number = right(account_last4, 4)
where account_number = '';

drop function if exists public.request_withdrawal(numeric, text, text, text);

create function public.request_withdrawal(
  p_amount numeric,
  p_account_name text,
  p_account_number text,
  p_bank_name text
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
  clean_account_number text := regexp_replace(coalesce(p_account_number, ''), '[^0-9]', '', 'g');
begin
  if current_user_id is null then
    raise exception 'Sign in to request a withdrawal.';
  end if;
  if p_amount is null or p_amount < 100 or p_amount > 999999999999.99
     or p_amount <> trunc(p_amount, 2) then
    raise exception 'Enter a withdrawal amount of at least NGN 100, with at most two decimal places.';
  end if;
  if nullif(trim(p_account_name), '') is null or length(trim(p_account_name)) > 160 then
    raise exception 'Enter the bank account holder name.';
  end if;
  if coalesce(p_account_number, '') !~ '^[0-9[:space:]-]+$' then
    raise exception 'Use digits only for the bank account number.';
  end if;
  if clean_account_number !~ '^[0-9]{10,20}$' then
    raise exception 'Enter a valid bank account number containing 10 to 20 digits.';
  end if;
  if nullif(trim(p_bank_name), '') is null or length(trim(p_bank_name)) > 100 then
    raise exception 'Enter the bank name.';
  end if;

  update public.wallets
  set balance = balance - p_amount, updated_at = now()
  where user_id = current_user_id and balance >= p_amount;
  if not found then
    raise exception 'Your available wallet balance is too low for this withdrawal.';
  end if;

  insert into public.transactions (user_id, type, amount, status, description)
  values (current_user_id, 'withdrawal', p_amount, 'pending', 'Withdrawal request')
  returning * into transaction_row;

  insert into public.withdrawals (
    user_id, amount, bank_name, account_last4, account_name, account_number, transaction_id
  )
  values (
    current_user_id, p_amount, trim(p_bank_name), right(clean_account_number, 4),
    trim(p_account_name), clean_account_number, transaction_row.id
  )
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
  from public.deposits
  where id = p_deposit_id
  for update;
  if not found then
    raise exception 'Deposit request not found.';
  end if;

  if p_decision = 'restore' then
    if deposit_row.status <> 'rejected' then
      raise exception 'Only rejected deposits can be restored.';
    end if;
    update public.deposits
    set status = 'pending',
        expires_at = now() + interval '25 minutes',
        admin_note = '',
        reviewed_by = null,
        reviewed_at = null
    where id = p_deposit_id
    returning * into deposit_row;
    update public.transactions
    set status = 'pending',
        description = 'Restored manual deposit request ' || deposit_row.id::text
    where id = deposit_row.transaction_id;
    return deposit_row;
  end if;

  if deposit_row.status not in ('pending', 'rejected') then
    raise exception 'Only pending or rejected deposits can be reviewed.';
  end if;
  if deposit_row.status = 'pending'
     and deposit_row.expires_at <= now()
     and deposit_row.payment_submitted_at is null then
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

revoke all on function public.request_withdrawal(numeric, text, text, text) from public, anon;
grant execute on function public.request_withdrawal(numeric, text, text, text) to authenticated;
revoke all on function public.admin_review_deposit(uuid, text, text) from public, anon;
grant execute on function public.admin_review_deposit(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';

commit;
