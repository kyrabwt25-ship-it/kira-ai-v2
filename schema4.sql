-- KIRA AI V2 hardening migration (OpenRouter-compatible)
-- Run AFTER schema.sql, schema2.sql, and schema3.sql in Supabase SQL Editor.
-- This migration does not change model IDs; it hardens payment/profile handling.

begin;

-- 1) Useful indexes
create index if not exists payments_status_created_idx
  on public.payments(status, created_at desc);

create index if not exists payments_user_created_idx
  on public.payments(user_id, created_at desc);

create index if not exists profiles_email_lower_idx
  on public.profiles(lower(email));

create index if not exists usage_day_idx
  on public.usage(day);

-- 2) Keep profile email synchronized with Supabase Auth
create or replace function public.sync_profile_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles
  set email = new.email
  where id = new.id;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_updated on auth.users;

create trigger on_auth_user_email_updated
after update of email on auth.users
for each row
when (old.email is distinct from new.email)
execute function public.sync_profile_email();

-- 3) Atomic payment confirmation and subscription activation
-- Gateway callers must pass the amount actually confirmed by the trusted gateway.
-- Manual confirmation should only be reachable through an admin-authorized server endpoint.
create or replace function public.activate_payment_atomic(
  p_payment_id uuid,
  p_method text,
  p_gateway_amount numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  pay public.payments%rowtype;
  prof public.profiles%rowtype;
  plan_days integer;
  base_time timestamptz;
  new_expiry timestamptz;
begin
  select *
  into pay
  from public.payments
  where id = p_payment_id
  for update;

  if not found then
    raise exception 'payment_not_found' using errcode = 'P0002';
  end if;

  if pay.status = 'paid' then
    return jsonb_build_object(
      'ok', true,
      'already_paid', true
    );
  end if;

  if pay.status <> 'pending' then
    raise exception 'payment_not_pending' using errcode = 'P0001';
  end if;

  if pay.user_id is null then
    raise exception 'payment_user_missing' using errcode = 'P0001';
  end if;

  if pay.amount is null or pay.amount <= 0 then
    raise exception 'invalid_payment_amount' using errcode = 'P0001';
  end if;

  if p_method = 'gateway' then
    if p_gateway_amount is null
       or round(p_gateway_amount, 2) <> round(pay.amount, 2) then
      raise exception 'payment_amount_mismatch' using errcode = 'P0001';
    end if;
  elsif p_method is null or length(trim(p_method)) = 0 then
    raise exception 'invalid_payment_method' using errcode = 'P0001';
  end if;

  if pay.period = 'weekly' then
    plan_days := 7;
  elsif pay.period = 'monthly' then
    plan_days := 30;
  elsif pay.period = 'yearly' then
    plan_days := 365;
  else
    raise exception 'invalid_payment_period' using errcode = 'P0001';
  end if;

  if not exists (
    select 1 from public.plans where id = pay.plan_id
  ) then
    raise exception 'invalid_plan' using errcode = 'P0001';
  end if;

  select *
  into prof
  from public.profiles
  where id = pay.user_id
  for update;

  if not found then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;

  base_time := now();

  if prof.plan_id = pay.plan_id
     and prof.plan_expires_at is not null then
    base_time := greatest(base_time, prof.plan_expires_at);
  end if;

  new_expiry := base_time + make_interval(days => plan_days);

  update public.profiles
  set plan_id = pay.plan_id,
      plan_expires_at = new_expiry
  where id = pay.user_id;

  update public.payments
  set status = 'paid',
      method = left(coalesce(p_method, 'manual'), 40),
      paid_at = now()
  where id = pay.id;

  return jsonb_build_object(
    'ok', true,
    'already_paid', false,
    'expires_at', new_expiry
  );
end;
$$;

-- Only the trusted backend using service_role can execute this function.
revoke all
on function public.activate_payment_atomic(uuid, text, numeric)
from public;

revoke all
on function public.activate_payment_atomic(uuid, text, numeric)
from anon;

revoke all
on function public.activate_payment_atomic(uuid, text, numeric)
from authenticated;

grant execute
on function public.activate_payment_atomic(uuid, text, numeric)
to service_role;

-- 4) Keep the configured owner as admin.
-- Ensure this email matches DEVELOPER_EMAIL in Render.
update public.profiles
set role = 'admin'
where lower(email) = lower('kyrabwt22@gmail.com');

-- Demote other admin roles. Review this policy before running if your project
-- intentionally has more than one administrator.
update public.profiles
set role = 'user'
where lower(coalesce(email, '')) <> lower('kyrabwt22@gmail.com')
  and role = 'admin';

commit;

-- Security notes:
-- * Do not create client-side INSERT/UPDATE policies for profiles.role,
--   profiles.plan_id, profiles.plan_expires_at, payments.status, or payments.paid_at.
-- * Never expose the Supabase service_role key in browser/mobile client code.
-- * Vodafone Cash/manual payments must be checked by an authorized admin before
--   the backend calls activate_payment_atomic(..., 'manual', null).
-- * For a payment gateway, only call the function after validating the gateway's
--   trusted server-side confirmation and pass the verified amount.
-- * This SQL does not bypass the application's payment screen or alter OpenRouter billing.
