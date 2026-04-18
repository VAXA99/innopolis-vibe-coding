-- Запустите в Supabase: SQL Editor → New query → Run
-- Таблица для копии регистраций из приложения (запись только с сервера через service_role).

create table if not exists public.app_registrations (
  email text primary key,
  full_name text,
  registered_at timestamptz not null default now()
);

create index if not exists app_registrations_registered_at_idx on public.app_registrations (registered_at desc);

comment on table public.app_registrations is 'Регистрации из iOS → Render; дублируются из Node для просмотра в Supabase.';
