-- ============================================================
-- قاعدة بيانات حجز مرافق جمعية التنمية الأهلية بعنيزة
-- تُنفَّذ مرة واحدة في Supabase > SQL Editor
-- ============================================================

create table if not exists public.bookings (
  id               uuid primary key default gen_random_uuid(),
  facility         text not null check (facility in ('theater','training','lab','events')),
  title            text not null check (char_length(title) between 2 and 120),
  description      text not null check (char_length(description) <= 1000),
  department       text not null check (char_length(department) <= 80),
  partner          text default '' check (char_length(partner) <= 120),
  attendees        int  not null check (attendees between 1 and 5000),
  start_at         timestamptz not null,
  end_at           timestamptz not null,
  applicant_name   text not null check (char_length(applicant_name) <= 80),
  applicant_phone  text not null check (char_length(applicant_phone) <= 15),
  status           text not null default 'pending' check (status in ('pending','approved','rejected')),
  officer          text default '',
  admin_note       text default '',
  amount           numeric(12,2) not null default 0 check (amount >= 0),  -- المبلغ المدفوع (للمسؤول فقط)
  created_at       timestamptz not null default now(),
  check (end_at > start_at)
);

-- لمن أنشأ الجدول بنسخة سابقة: إضافة عمود المبلغ
alter table public.bookings add column if not exists amount numeric(12,2) not null default 0 check (amount >= 0);

create index if not exists bookings_time_idx on public.bookings (start_at, end_at);

alter table public.bookings enable row level security;

-- أي زائر يستطيع إرسال طلب جديد فقط بحالة «قيد الاعتماد» ودون تعيين مسؤول
drop policy if exists "public can request" on public.bookings;
create policy "public can request" on public.bookings
  for insert to anon, authenticated
  with check (status = 'pending' and coalesce(officer,'') = '' and coalesce(admin_note,'') = '' and amount = 0);

-- المسؤولون: فقط الحسابات المضافة إلى جدول booking_admins
create table if not exists public.booking_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.booking_admins enable row level security;

create or replace function public.is_booking_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.booking_admins where user_id = auth.uid());
$$;
grant execute on function public.is_booking_admin() to anon, authenticated;

drop policy if exists "admins read" on public.bookings;
create policy "admins read" on public.bookings
  for select to authenticated using (public.is_booking_admin());

drop policy if exists "admins update" on public.bookings;
create policy "admins update" on public.bookings
  for update to authenticated using (public.is_booking_admin()) with check (public.is_booking_admin());

drop policy if exists "admins delete" on public.bookings;
create policy "admins delete" on public.bookings
  for delete to authenticated using (public.is_booking_admin());

-- عرض عام للتقويم: أوقات الإشغال فقط (المرفق ومن/إلى) دون أي تفاصيل عن الفعالية أو مقدّمها
drop view if exists public.bookings_public;
create or replace view public.bookings_busy as
  select facility, start_at, end_at, (status = 'approved') as confirmed
  from public.bookings
  where status <> 'rejected';

grant select on public.bookings_busy to anon, authenticated;

-- استعلام مقدّم الطلب عن طلبه برقم الطلب (أول 8 خانات) + الجوال
create or replace function public.lookup_booking(p_ref text, p_phone text)
returns table (title text, facility text, start_at timestamptz, end_at timestamptz,
               status text, officer text, admin_note text)
language sql security definer set search_path = public as $$
  select b.title, b.facility, b.start_at, b.end_at, b.status, b.officer, b.admin_note
  from public.bookings b
  where length(p_ref) = 8
    and left(b.id::text, 8) = lower(p_ref)
    and b.applicant_phone = p_phone
  limit 1;
$$;

revoke all on function public.lookup_booking(text, text) from public;
grant execute on function public.lookup_booking(text, text) to anon, authenticated;

-- بعد إنشاء حساب المسؤول من Authentication > Users، أضفه مسؤولًا بتغيير البريد ثم تشغيل:
-- insert into public.booking_admins (user_id) select id from auth.users where email = 'admin@example.com';
