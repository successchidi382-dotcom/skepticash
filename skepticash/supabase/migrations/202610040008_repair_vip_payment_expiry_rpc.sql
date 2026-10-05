begin;

create or replace function public.admin_expire_vip_payments()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  affected_rows integer;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;

  update public.vip_payment_requests
  set status = 'expired' 
  where status = 'pending'
    and payment_submitted_at is null
    and expires_at <= now();

  get diagnostics affected_rows = row_count;
  return affected_rows;
end;
$$;

revoke all on function public.admin_expire_vip_payments() from public, anon;
grant execute on function public.admin_expire_vip_payments() to authenticated;

notify pgrst, 'reload schema';

commit;
