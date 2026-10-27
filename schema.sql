-- KIRA AI — Supabase Database Setup (OpenRouter)
-- شغّل في Supabase > SQL Editor

begin;

-- 1) جدول الباقات
create table if not exists public.plans (
  id text primary key,
  name text not null,
  model text not null,
  daily_messages int not null,
  daily_images int not null,
  max_tokens int not null,
  style_rule text not null default '',
  sort int not null default 0,
  price_weekly numeric default 0,
  price_monthly numeric default 0,
  price_yearly numeric default 0
);

alter table public.plans
  add column if not exists price_weekly numeric default 0;
alter table public.plans
  add column if not exists price_monthly numeric default 0;
alter table public.plans
  add column if not exists price_yearly numeric default 0;
alter table public.plans
  add column if not exists style_rule text not null default '';
alter table public.plans
  add column if not exists sort int not null default 0;

-- 2) الباقات تستخدم OpenRouter بدل Claude
-- الباقات المدفوعة هنا تستخدم النموذج نفسه أيضًا،
-- لكن هذا لا يلغي بوابة الدفع الموجودة في التطبيق.
insert into public.plans
  (id, name, model, daily_messages, daily_images,
   max_tokens, style_rule, sort,
   price_weekly, price_monthly, price_yearly)
values
  (
    'free', 'Free', 'openrouter/free',
    20, 3, 500,
    'أجب باختصار ووضوح.',
    0, 0, 0, 0
  ),
  (
    'plus', 'Plus', 'openrouter/free',
    100, 15, 1500,
    'اشرح بالتفصيل مع خطوات الحل وأمثلة.',
    1, 0, 0, 0
  ),
  (
    'pro', 'Pro', 'openrouter/free',
    300, 50, 3000,
    'قدّم تحليلًا منظمًا وحلولًا كاملة.',
    2, 0, 0, 0
  ),
  (
    'ultra', 'Ultra', 'openrouter/free',
    1000, 150, 4000,
    'قدّم شرحًا معمقًا وأمثلة وتحققًا من الحل.',
    3, 0, 0, 0
  )
on conflict (id) do update set
  name = excluded.name,
  model = excluded.model,
  daily_messages = excluded.daily_messages,
  daily_images = excluded.daily_images,
  max_tokens = excluded.max_tokens,
  style_rule = excluded.style_rule,
  sort = excluded.sort;

-- 3) ملفات المستخدمين
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  plan_id text not null default 'free'
    references public.plans(id),
  plan_expires_at timestamptz,
  role text not null default 'user',
  created_at timestamptz default now()
);

-- 4) عدّاد الاستخدام اليومي
create table if not exists public.usage (
  user_id uuid references auth.users(id) on delete cascade,
  day date not null default current_date,
  messages int not null default 0,
  images int not null default 0,
  primary key (user_id, day)
);

-- 5) أمان الجداول
alter table public.plans enable row level security;
alter table public.profiles enable row level security;
alter table public.usage enable row level security;

drop policy if exists "plans readable" on public.plans;
create policy "plans readable"
on public.plans for select
to anon, authenticated
using (true);

drop policy if exists "own profile" on public.profiles;
create policy "own profile"
on public.profiles for select
to authenticated
using (auth.uid() = id);

drop policy if exists "own usage" on public.usage;
create policy "own usage"
on public.usage for select
to authenticated
using (auth.uid() = user_id);

-- 6) إنشاء ملف المستخدم عند التسجيل
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do update
    set email = excluded.email;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();

-- 7) عداد الاستخدام اليومي
create or replace function public.bump_usage(
  p_user uuid,
  p_images int,
  p_max_msgs int,
  p_max_imgs int
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.usage%rowtype;
begin
  if p_user is null
     or coalesce(p_images, 0) < 0
     or coalesce(p_max_msgs, 0) < 0
     or coalesce(p_max_imgs, 0) < 0 then
    return 'invalid';
  end if;

  insert into public.usage (user_id, day)
  values (p_user, current_date)
  on conflict (user_id, day) do nothing;

  select *
  into r
  from public.usage
  where user_id = p_user
    and day = current_date
  for update;

  if r.messages >= p_max_msgs then
    return 'messages';
  end if;

  if r.images + p_images > p_max_imgs then
    return 'images';
  end if;

  update public.usage
  set messages = messages + 1,
      images = images + p_images
  where user_id = p_user
    and day = current_date;

  return 'ok';
end;
$$;

revoke all
on function public.bump_usage(uuid, int, int, int)
from public;

revoke all
on function public.bump_usage(uuid, int, int, int)
from anon;

revoke all
on function public.bump_usage(uuid, int, int, int)
from authenticated;

grant execute
on function public.bump_usage(uuid, int, int, int)
to service_role;

commit;

-- 8) عرض الباقات للتأكد من التعديل
select id, name, model, daily_messages,
       daily_images, max_tokens
from public.plans
order by sort;
