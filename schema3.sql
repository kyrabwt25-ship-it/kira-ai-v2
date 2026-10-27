-- KIRA AI — Schema v3: معلمون + Vodafone Cash + إعلانات + مطوّر تلقائي
-- شغّل بعد schema.sql و schema2.sql و schema3 السابق (إن وجد).
-- يستخدم OpenRouter بدل أسماء Claude القديمة.

begin;

-- 1) أعمدة إضافية
alter table public.profiles
  add column if not exists account_type text not null default 'student';

alter table public.plans
  add column if not exists kind text not null default 's';

alter table public.payments
  add column if not exists from_number text;

alter table public.payments
  add column if not exists tx text;

-- 2) إعلانات
create table if not exists public.announcements (
  id bigserial primary key,
  text text not null,
  created_at timestamptz default now()
);

alter table public.announcements enable row level security;

-- لا توجد سياسات للعميل هنا؛ يفترض أن الوصول يتم من الخادم باستخدام service_role.

-- 3) باقات الطلاب: تأكد من أن kind = s
update public.plans
set kind = 's'
where id in ('free', 'plus', 'pro', 'ultra');

-- 4) باقات المعلمين باستخدام OpenRouter بدل Claude
-- الأسعار تبدأ من صفر؛ عيّن الأسعار المناسبة لاحقًا من لوحة الإدارة.
insert into public.plans
  (id, name, model, daily_messages, daily_images, max_tokens,
   style_rule, sort, kind, price_weekly, price_monthly, price_yearly)
values
  ('tfree', 'Teacher Free', 'openrouter/free', 20, 3, 800,
   'أجب بإيجاز مفيد للمعلم مع أبرز النقاط العملية. قدّم شرحًا مناسبًا للسؤال.',
   10, 't', 0, 0, 0),
  ('tplus', 'Teacher Plus', 'openrouter/free', 120, 30, 3000,
   'قدّم إجابات مفصلة مع أمثلة وطرق تدريس وأساليب تقويم.',
   11, 't', 0, 0, 0),
  ('tpro', 'Teacher Pro', 'openrouter/free', 300, 100, 4000,
   'قدّم تحليلًا منظمًا ومواد تعليمية جاهزة للاستخدام في الفصل.',
   12, 't', 0, 0, 0),
  ('tultra', 'Teacher Ultra', 'openrouter/free', 800, 300, 5000,
   'قدّم مواد تعليمية متكاملة، وتحقق من الدقة، وراعِ اختلاف المستويات.',
   13, 't', 0, 0, 0)
on conflict (id) do update set
  name = excluded.name,
  model = excluded.model,
  daily_messages = excluded.daily_messages,
  daily_images = excluded.daily_images,
  max_tokens = excluded.max_tokens,
  style_rule = excluded.style_rule,
  sort = excluded.sort,
  kind = excluded.kind;

-- 5) تعيين حساب المطوّر مديرًا تلقائيًا عند التسجيل
-- تأكد أن البريد أدناه هو بريد المطوّر الصحيح.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, role)
  values (
    new.id,
    new.email,
    case
      when lower(coalesce(new.email, '')) = 'kyrabwt22@gmail.com'
      then 'admin'
      else 'user'
    end
  )
  on conflict (id) do update
    set email = excluded.email;

  return new;
end;
$$;

-- ترقية الحساب الموجود بالفعل بهذا البريد إلى مدير
update public.profiles
set role = 'admin'
where lower(email) = 'kyrabwt22@gmail.com';

-- 6) تحديث شخصية المساعد: الحل المباشر افتراضيًا
-- لا نكرر النص في كل تشغيل.
update public.settings
set value = value ||
  ' عندما يطلب الطالب حلّ سؤال، قدّم الحل مع الخطوات بوضوح، إلا إذا اختار وضع المعلم.'
where key = 'persona'
  and position(
    'عندما يطلب الطالب حلّ سؤال، قدّم الحل مع الخطوات بوضوح'
    in value
  ) = 0;

commit;

-- 7) تحقق من باقات الطلاب والمعلمين
select id, name, model, kind, daily_messages, daily_images,
       max_tokens, price_weekly, price_monthly, price_yearly
from public.plans
order by sort;

-- 8) اختياري: تعيين أسعار المعلمين بضعف أسعار باقات الطلاب.
-- شغّل هذا منفصلًا بعد تحديد أسعار باقات الطلاب:
-- update public.plans as t
-- set price_weekly = s.price_weekly * 2,
--     price_monthly = s.price_monthly * 2,
--     price_yearly = s.price_yearly * 2
-- from public.plans as s
-- where t.id = 't' || s.id
--   and s.id in ('plus', 'pro', 'ultra');

-- ملاحظة Vodafone Cash:
-- هذا السكربت يضيف from_number و tx لتخزين رقم المرسل ورقم/مرجع العملية.
-- لا يتحقق من الدفع تلقائيًا؛ يجب أن يراجع الخادم/المشرف العملية قبل تغيير status إلى paid.

-- بعد تحديد أسعار باقات الطلاب شغّل هذا لمضاعفتها للمعلمين:
-- update plans t set price_weekly=s.price_weekly*2, price_monthly=s.price_monthly*2, price_yearly=s.price_yearly*2
--   from plans s where t.id='t'||s.id and s.id in ('plus','pro','ultra');
