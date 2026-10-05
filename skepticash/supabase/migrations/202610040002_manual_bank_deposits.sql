begin;

alter table public.announcements
  add column if not exists title text not null default 'Announcement';

alter table public.deposits
  alter column proof_path drop not null;

alter table public.deposits
  add column if not exists full_name text not null default '',
  add column if not exists email text not null default '',
  add column if not exists expires_at timestamptz;

update public.deposits as deposit
set full_name = coalesce(nullif(deposit.full_name, ''), profile.full_name, 'Member'),
    email = coalesce(nullif(deposit.email, ''), auth_user.email, ''),
    expires_at = coalesce(deposit.expires_at, deposit.created_at + interval '25 minutes')
from public.profiles as profile
left join auth.users as auth_user on auth_user.id = profile.id
where profile.id = deposit.user_id
  and (deposit.full_name = '' or deposit.email = '' or deposit.expires_at is null);

update public.deposits
set full_name = 'Member',
    email = 'unknown@example.invalid',
    expires_at = coalesce(expires_at, created_at + interval '25 minutes')
where full_name = '' or email = '' or expires_at is null;

alter table public.deposits
  alter column full_name set not null,
  alter column email set not null,
  alter column expires_at set default (now() + interval '25 minutes'),
  alter column expires_at set not null;

do $$
declare
  constraint_name text;
begin
  for constraint_name in
    select conname
    from pg_catalog.pg_constraint
    where conrelid = 'public.deposits'::regclass
      and contype = 'c'
      and pg_catalog.pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute pg_catalog.format('alter table public.deposits drop constraint %I', constraint_name);
  end loop;
end;
$$;

alter table public.deposits
  add constraint deposits_status_check
  check (status in ('pending', 'approved', 'rejected', 'expired', 'completed'));

do $$
declare
  constraint_name text;
begin
  for constraint_name in
    select conname
    from pg_catalog.pg_constraint
    where conrelid = 'public.transactions'::regclass
      and contype = 'c'
      and pg_catalog.pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute pg_catalog.format('alter table public.transactions drop constraint %I', constraint_name);
  end loop;
end;
$$;

alter table public.transactions
  add constraint transactions_status_check
  check (status in ('pending', 'completed', 'approved', 'rejected', 'failed', 'expired'));

create index if not exists deposits_expiration_idx
  on public.deposits (status, expires_at)
  where status = 'pending';

insert into public.platform_settings (key, value)
values (
  'manual_deposit_details',
  '{"account_name":"","account_number":"","bank_name":"","instruction":""}'::jsonb
)
on conflict (key) do nothing;

create or replace function public.get_manual_deposit_details()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  details jsonb;
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in to view deposit instructions.';
  end if;

  select value into details
  from public.platform_settings
  where key = 'manual_deposit_details';

  if details is null
     or nullif(trim(details ->> 'account_name'), '') is null
     or nullif(trim(details ->> 'account_number'), '') is null
     or nullif(trim(details ->> 'bank_name'), '') is null then
    raise exception 'Bank transfer details have not been configured yet. Contact support.';
  end if;
  return details;
end;
$$;

create or replace function public.admin_save_manual_deposit_details(
  p_account_name text,
  p_account_number text,
  p_bank_name text,
  p_instruction text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  details jsonb;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;
  if nullif(trim(p_account_name), '') is null or length(trim(p_account_name)) > 160 then
    raise exception 'Enter an account name of up to 160 characters.';
  end if;
  if nullif(trim(p_account_number), '') is null or length(trim(p_account_number)) > 40 then
    raise exception 'Enter an account number of up to 40 characters.';
  end if;
  if nullif(trim(p_bank_name), '') is null or length(trim(p_bank_name)) > 120 then
    raise exception 'Enter a bank name of up to 120 characters.';
  end if;
  if length(coalesce(p_instruction, '')) > 2000 then
    raise exception 'Payment instructions must be 2,000 characters or fewer.';
  end if;

  details := pg_catalog.jsonb_build_object(
    'account_name', trim(p_account_name),
    'account_number', trim(p_account_number),
    'bank_name', trim(p_bank_name),
    'instruction', trim(coalesce(p_instruction, ''))
  );
  insert into public.platform_settings (key, value)
  values ('manual_deposit_details', details)
  on conflict (key) do update
    set value = excluded.value, updated_at = now();
  return details;
end;
$$;

create or replace function public.create_manual_deposit(
  p_full_name text,
  p_email text,
  p_amount numeric
)
returns public.deposits
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  account_email text;
  deposit_row public.deposits%rowtype;
  transaction_row public.transactions%rowtype;
begin
  if current_user_id is null then
    raise exception 'Sign in to create a deposit request.';
  end if;
  if nullif(trim(p_full_name), '') is null or length(trim(p_full_name)) > 160 then
    raise exception 'Enter your full name (up to 160 characters).';
  end if;
  if p_email is null or length(trim(p_email)) > 320
     or trim(p_email) !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then
    raise exception 'Enter a valid email address.';
  end if;
  select email into account_email from auth.users where id = current_user_id;
  if account_email is null or lower(trim(p_email)) <> lower(account_email) then
    raise exception 'Use the email address registered to your signed-in account.';
  end if;
  if p_amount is null or p_amount < 100 or p_amount > 999999999999.99
     or p_amount <> round(p_amount, 2) then
    raise exception 'Enter a deposit amount of at least ₦100.';
  end if;

  perform public.get_manual_deposit_details();

  insert into public.transactions (user_id, type, amount, status, description)
  values (current_user_id, 'deposit', p_amount, 'pending', 'Manual bank transfer deposit')
  returning * into transaction_row;

  insert into public.deposits (
    user_id, full_name, email, amount, status, transaction_id, expires_at
  )
  values (
    current_user_id, trim(p_full_name), lower(trim(p_email)), p_amount, 'pending',
    transaction_row.id, now() + interval '25 minutes'
  )
  returning * into deposit_row;

  update public.transactions
  set description = 'Manual deposit request ' || deposit_row.id::text
  where id = transaction_row.id;
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
    and expires_at <= now()
  returning * into deposit_row;

  if found then
    update public.transactions set status = 'expired'
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
    where status = 'pending' and expires_at <= now()
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

  if deposit_row.expires_at <= now() then
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
        else 'Manual deposit request ' || deposit_row.id::text || ' — ' || deposit_row.admin_note
      end
  where id = deposit_row.transaction_id;
  return deposit_row;
end;
$$;

revoke all on function public.get_manual_deposit_details() from public, anon;
revoke all on function public.admin_save_manual_deposit_details(text, text, text, text) from public, anon;
revoke all on function public.create_manual_deposit(text, text, numeric) from public, anon;
revoke all on function public.expire_manual_deposit(uuid) from public, anon;
revoke all on function public.expire_user_manual_deposits() from public, anon;
revoke all on function public.admin_expire_manual_deposits() from public, anon;
revoke all on function public.admin_review_deposit(uuid, text, text) from public, anon;

grant execute on function public.get_manual_deposit_details() to authenticated;
grant execute on function public.admin_save_manual_deposit_details(text, text, text, text) to authenticated;
grant execute on function public.create_manual_deposit(text, text, numeric) to authenticated;
grant execute on function public.expire_manual_deposit(uuid) to authenticated;
grant execute on function public.expire_user_manual_deposits() to authenticated;
grant execute on function public.admin_expire_manual_deposits() to authenticated;
grant execute on function public.admin_review_deposit(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';

commit;
