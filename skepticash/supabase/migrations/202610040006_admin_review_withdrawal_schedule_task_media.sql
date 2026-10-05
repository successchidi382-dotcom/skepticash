begin;

insert into public.platform_settings (key, value)
values ('withdrawal_days', '[0,1,2,3,4,5,6]'::jsonb)
on conflict (key) do nothing;

alter table public.tasks
  add column if not exists media_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'task-media',
  'task-media',
  false,
  20971520,
  array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime']
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "task media read active member tasks" on storage.objects;
create policy "task media read active member tasks"
on storage.objects for select to authenticated
using (
  bucket_id = 'task-media'
  and (
    (select public.is_admin())
    or exists (
      select 1
      from public.tasks as task
      where task.media_path = name and task.active
    )
  )
);

drop policy if exists "task media admin insert" on storage.objects;
create policy "task media admin insert"
on storage.objects for insert to authenticated
with check (bucket_id = 'task-media' and (select public.is_admin()));

drop policy if exists "task media admin update" on storage.objects;
create policy "task media admin update"
on storage.objects for update to authenticated
using (bucket_id = 'task-media' and (select public.is_admin()))
with check (bucket_id = 'task-media' and (select public.is_admin()));

drop policy if exists "task media admin delete" on storage.objects;
create policy "task media admin delete"
on storage.objects for delete to authenticated
using (bucket_id = 'task-media' and (select public.is_admin()));

create or replace function public.get_withdrawal_days()
returns integer[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  configured_days jsonb;
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in to view withdrawal availability.';
  end if;
  select value into configured_days
  from public.platform_settings
  where key = 'withdrawal_days';
  return array(
    select jsonb_array_elements_text(coalesce(configured_days, '[0,1,2,3,4,5,6]'::jsonb))::integer
    order by 1
  );
end;
$$;

create or replace function public.admin_save_withdrawal_days(p_days integer[])
returns integer[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_days integer[];
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;
  if p_days is null or cardinality(p_days) = 0
     or exists (select 1 from unnest(p_days) as days(day) where day < 0 or day > 6) then
    raise exception 'Select at least one valid weekday.';
  end if;
  select array_agg(distinct day order by day)
  into clean_days
  from unnest(p_days) as days(day);

  insert into public.platform_settings (key, value)
  values ('withdrawal_days', to_jsonb(clean_days))
  on conflict (key) do update
  set value = excluded.value, updated_at = now();
  return clean_days;
end;
$$;

create or replace function public.request_withdrawal(
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
  allowed_days integer[];
  clean_account_number text := regexp_replace(coalesce(p_account_number, ''), '[^0-9]', '', 'g');
begin
  if current_user_id is null then
    raise exception 'Sign in to request a withdrawal.';
  end if;
  select public.get_withdrawal_days() into allowed_days;
  if extract(dow from (now() at time zone 'Africa/Lagos'))::integer <> all(allowed_days) then
    raise exception 'Withdrawals can only be requested on the configured withdrawal day(s).';
  end if;
  if p_amount is null or p_amount < 100 or p_amount > 999999999999.99
     or p_amount <> trunc(p_amount, 2) then
    raise exception 'Enter a withdrawal amount of at least NGN 100, with at most two decimal places.';
  end if;
  if nullif(trim(p_account_name), '') is null or length(trim(p_account_name)) > 160 then
    raise exception 'Enter the bank account holder name.';
  end if;
  if coalesce(p_account_number, '') !~ '^[0-9[:space:]-]+$'
     or clean_account_number !~ '^[0-9]{10,20}$' then
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
  previously_reserved boolean;
  should_reserve boolean;
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

  select * into withdrawal_row
  from public.withdrawals
  where id = p_withdrawal_id
  for update;
  if not found then
    raise exception 'Withdrawal request not found.';
  end if;

  previously_reserved := withdrawal_row.status in ('pending', 'approved');
  should_reserve := p_decision = 'approved';
  if previously_reserved is distinct from should_reserve then
    if should_reserve then
      update public.wallets
      set balance = balance - withdrawal_row.amount, updated_at = now()
      where user_id = withdrawal_row.user_id and balance >= withdrawal_row.amount;
      if not found then
        raise exception 'Member wallet balance is too low to approve this previously rejected withdrawal.';
      end if;
    else
      update public.wallets
      set balance = balance + withdrawal_row.amount, updated_at = now()
      where user_id = withdrawal_row.user_id;
      if not found then
        raise exception 'Member wallet not found.';
      end if;
    end if;
  end if;

  update public.withdrawals
  set status = p_decision,
      admin_note = coalesce(trim(p_admin_note), ''),
      reviewed_by = (select auth.uid()),
      reviewed_at = now()
  where id = p_withdrawal_id
  returning * into withdrawal_row;

  update public.transactions
  set status = p_decision,
      description = case
        when withdrawal_row.admin_note = '' then 'Withdrawal request ' || withdrawal_row.id::text
        else 'Withdrawal request ' || withdrawal_row.id::text || ' - ' || withdrawal_row.admin_note
      end
  where id = withdrawal_row.transaction_id;
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

  was_credited := deposit_row.status in ('approved', 'completed');
  should_credit := p_decision = 'approved';
  new_status := case when should_credit then 'completed' else 'rejected' end;
  if was_credited is distinct from should_credit then
    if should_credit then
      update public.wallets
      set balance = balance + deposit_row.amount, updated_at = now()
      where user_id = deposit_row.user_id;
      if not found then
        raise exception 'Member wallet not found.';
      end if;
    else
      update public.wallets
      set balance = balance - deposit_row.amount, updated_at = now()
      where user_id = deposit_row.user_id and balance >= deposit_row.amount;
      if not found then
        raise exception 'Member wallet does not have enough balance to reverse this deposit.';
      end if;
    end if;
  end if;

  update public.deposits
  set status = new_status,
      admin_note = coalesce(trim(p_admin_note), ''),
      reviewed_by = (select auth.uid()),
      reviewed_at = now()
  where id = p_deposit_id
  returning * into deposit_row;

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

revoke all on function public.get_withdrawal_days() from public, anon;
grant execute on function public.get_withdrawal_days() to authenticated;
revoke all on function public.admin_save_withdrawal_days(integer[]) from public, anon;
grant execute on function public.admin_save_withdrawal_days(integer[]) to authenticated;
revoke all on function public.request_withdrawal(numeric, text, text, text) from public, anon;
grant execute on function public.request_withdrawal(numeric, text, text, text) to authenticated;
revoke all on function public.admin_review_withdrawal(uuid, text, text) from public, anon;
grant execute on function public.admin_review_withdrawal(uuid, text, text) to authenticated;
revoke all on function public.admin_review_deposit(uuid, text, text) from public, anon;
grant execute on function public.admin_review_deposit(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';

commit;
