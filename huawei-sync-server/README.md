# Huawei Sync Server

Minimal bridge for app auto-sync.

## Fast local start

1. `cp .env.example .env`
2. Set `API_TOKEN` in `.env`
3. `npm start`

Use in app:
- Endpoint: `http://<your-ip>:8787/v1/huawei/summary`
- Access token: same `API_TOKEN`

## Free cloud deploy (Render)

1. Push this folder to GitHub.
2. In Render: New + -> Blueprint.
3. Select repository and deploy `render.yaml`.
4. Copy generated `API_TOKEN` from Render environment.

Use in app:
- Endpoint: `https://<your-render-app>.onrender.com/v1/huawei/summary`
- Access token: `API_TOKEN`

## Supabase (опционально)

Регистрации из приложения (`POST /v1/auth/register`) можно дублировать в Postgres Supabase для таблиц и SQL в дашборде.

1. Создайте проект на [supabase.com](https://supabase.com) (бесплатный tier).
2. **SQL Editor** → выполните скрипт из `supabase/migrations/001_app_registrations.sql`.
3. **Project Settings → API**: скопируйте **Project URL** и **service_role** (секретный ключ).
4. На Render (или в `.env` локально) задайте:
   - `SUPABASE_URL=https://xxxx.supabase.co`
   - `SUPABASE_SERVICE_ROLE_KEY=eyJ...` (только на сервере, не в iOS-приложении).

После деплоя новые регистрации появятся в **Table Editor** → `app_registrations`. Ответ API будет содержать поле `supabase`: `{ synced: true }` или ошибку синка.

## Notes

- Keep `.env` private; never commit it.
- Start with `MOCK_MODE=true`.
- Later set `MOCK_MODE=false` and configure `REMOTE_SOURCE_URL`.
