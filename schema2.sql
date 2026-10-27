-- KIRA AI — Schema v2: الإدارة + الدفع + المناهج
-- شغّل هذا الملف بعد schema.sql / ملف إعداد Supabase الأساسي.
-- آمن نسبيًا لإعادة التشغيل: يستخدم IF NOT EXISTS و UPSERT للإعدادات.

begin;

-- 1) إضافة حالة الحظر إلى ملفات المستخدمين
alter table public.profiles
  add column if not exists banned boolean not null default false;

-- 2) إعدادات التطبيق
create table if not exists public.settings (
  key text primary key,
  value text not null default ''
);

insert into public.settings (key, value)
values
(
  'persona',
  'أنت KIRA AI، مساعد تعليمي للطلبة. تكلّم بلغة الطالب (العربية افتراضيًا) وبأسلوب يناسب عمره. كن دقيقًا، وإن لم تتأكد فقل ذلك، ولا تخترع مراجع أو أرقام صفحات. اجعل المحتوى مناسبًا للأطفال دائمًا. عند إرسال صورة، حلّل ما فيها واشرحها أو ساعد في حل المسألة.'
),
('maintenance', '')
on conflict (key) do nothing;

-- 3) سجل عمليات الدفع
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade,
  plan_id text references public.plans(id),
  period text check (period in ('weekly', 'monthly', 'yearly')),
  amount numeric default 0,
  status text not null default 'pending',
  method text,
  created_at timestamptz default now(),
  paid_at timestamptz
);

-- 4) المستندات الدراسية
create table if not exists public.documents (
  id bigserial primary key,
  title text not null,
  level text,
  subject text,
  created_at timestamptz default now()
);

-- 5) أجزاء النصوص المفهرسة للبحث
create table if not exists public.chunks (
  id bigserial primary key,
  doc_id bigint references public.documents(id) on delete cascade,
  page int,
  content text not null,
  level text,
  subject text,
  tsv tsvector generated always as (
    to_tsvector('simple', coalesce(content, ''))
  ) stored
);

create index if not exists chunks_tsv
  on public.chunks using gin(tsv);

create index if not exists chunks_doc_id_idx
  on public.chunks (doc_id);

-- 6) تفعيل أمان الصفوف
alter table public.settings enable row level security;
alter table public.payments enable row level security;
alter table public.documents enable row level security;
alter table public.chunks enable row level security;

-- لا نضيف سياسات للعميل هنا؛ يُفترض أن الوصول لهذه الجداول يتم من الخادم
-- باستخدام service_role فقط. لا تضع service_role key في واجهة المتصفح.

-- 7) البحث في المناهج
create or replace function public.search_chunks(
  p_query text,
  p_level text,
  p_subject text,
  p_n int
)
returns table(title text, page int, content text)
language sql
stable
security definer
set search_path = public
as $$
  select d.title, c.page, c.content
  from public.chunks c
  join public.documents d on d.id = c.doc_id
  where
    -- to_tsquery قد يرفض صياغة بحث غير سليمة؛ يفضّل أن يرسل الخادم
    -- استعلامًا منسقًا (مثل كلمة أو كلمات مفصولة بـ &).
    c.tsv @@ plainto_tsquery('simple', coalesce(p_query, ''))
    and (c.level is null or c.level = p_level)
    and (c.subject is null or c.subject = p_subject)
  order by ts_rank(c.tsv, plainto_tsquery('simple', coalesce(p_query, ''))) desc
  limit greatest(1, least(coalesce(p_n, 5), 50));
$$;

revoke all on function public.search_chunks(text, text, text, int) from public;
revoke all on function public.search_chunks(text, text, text, int) from anon;
revoke all on function public.search_chunks(text, text, text, int) from authenticated;
grant execute on function public.search_chunks(text, text, text, int) to service_role;

commit;

-- 8) تحقق من الإعدادات والجداول
select key, value
from public.settings
where key in ('persona', 'maintenance')
order by key;

select id, name, model, sort
from public.plans
order by sort;

-- 9) اختياري: اجعل حسابك مديرًا بعد التسجيل.
-- غيّر البريد إلى البريد نفسه المستخدم في تسجيل KIRA AI ثم شغّل الأمر منفصلًا:
-- update public.profiles set role = 'admin' where email = 'you@example.com';
