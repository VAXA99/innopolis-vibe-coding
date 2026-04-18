-- После 001: разрешить вставку из iOS с публичным anon key (PostgREST).
-- Читать чужие строки anon не может — только insert.

alter table public.app_registrations enable row level security;

drop policy if exists "anon can insert app_registrations" on public.app_registrations;

create policy "anon can insert app_registrations"
on public.app_registrations
for insert
to anon
with check (true);
