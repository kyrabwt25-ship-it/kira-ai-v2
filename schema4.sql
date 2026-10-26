-- KIRA AI V2 hardening migration
-- Run AFTER schema.sql, schema2.sql, and schema3.sql in Supabase SQL Editor.

create index if not exists payments_status_created_idx on public.payments(status, created_at desc);
create index if not exists payments_user_created_idx on public.payments(user_id, created_at desc);
create index if not exists profiles_email_lower_idx on public.profiles(lower(email));
create index if not exists usage_day_idx on public.usage(day);

-- Keep account identity synchronized when a user changes email in Supabase Auth.
create or replace function public.sync_profile_email()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  update public.profiles set email = new.email where id = new.id;
  return new;
end $$;
drop trigger if exists on_auth_user_email_updated on auth.users;
create trigger on_auth_user_email_updated after update of email on auth.users
for each row when (old.email is distinct from new.email)
execute function public.sync_profile_email();

-- A single transaction confirms payment and activates subscription exactly once.
-- Gateway confirmations MUST pass the captured amount; manual confirmations are admin-only at API level.
create or replace function public.activate_payment_atomic(
  p_payment_id uuid,
  p_method text,
  p_gateway_amount numeric default null
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  pay public.payments%rowtype;
  prof public.profiles%rowtype;
  plan_days integer;
  base_time timestamptz;
  new_expiry timestamptz;
begin
  select * into pay from public.payments where id = p_payment_id for update;
  if not found then
    raise exception 'payment_not_found' using errcode='P0002';
  end if;
  if pay.status = 'paid' then
    return jsonb_build_object('ok', true, 'already_paid', true);
  end if;
  if pay.status <> 'pending' then
    raise exception 'payment_not_pending' using errcode='P0001';
  end if;
  if pay.amount is null or pay.amount <= 0 then
    raise exception 'invalid_payment_amount' using errcode='P0001';
  end if;
  if p_method = 'gateway' then
    if p_gateway_amount is null or round(p_gateway_amount, 2) <> round(pay.amount, 2) then
      raise exception 'payment_amount_mismatch' using errcode='P0001';
    end if;
  end if;
  if pay.period = 'weekly' then plan_days := 7;
  elsif pay.period = 'monthly' then plan_days := 30;
  elsif pay.period = 'yearly' then plan_days := 365;
  else raise exception 'invalid_payment_period' using errcode='P0001';
  end if;
  if not exists (select 1 from public.plans where id = pay.plan_id) then
    raise exception 'invalid_plan' using errcode='P0001';
  end if;

  select * into prof from public.profiles where id = pay.user_id for update;
  if not found then
    raise exception 'profile_not_found' using errcode='P0002';
  end if;
  base_time := now();
  if prof.plan_id = pay.plan_id and prof.plan_expires_at is not null then
    base_time := greatest(base_time, prof.plan_expires_at);
  end if;
  new_expiry := base_time + make_interval(days => plan_days);

  update public.profiles
    set plan_id = pay.plan_id, plan_expires_at = new_expiry
    where id = pay.user_id;
  update public.payments
    set status = 'paid', method = left(coalesce(p_method, 'manual'), 40), paid_at = now()
    where id = pay.id;

  return jsonb_build_object('ok', true, 'already_paid', false, 'expires_at', new_expiry);
end $$;

revoke all on function public.activate_payment_atomic(uuid, text, numeric) from public, anon, authenticated;
grant execute on function public.activate_payment_atomic(uuid, text, numeric) to service_role;

-- Ensure only the configured owner account has the admin role in this project.
-- Change the email below if DEVELOPER_EMAIL in Render is different.
update public.profiles set role = 'admin'
where lower(email) = lower('kyrabwt22@gmail.com');
update public.profiles set role = 'user'
where lower(email) <> lower('kyrabwt22@gmail.com') and role = 'admin';

-- Note: never add client-side INSERT/UPDATE policies for profiles.role, payments.status,
-- profiles.plan_id, or profiles.plan_expires_at. The service key belongs on the server only.
