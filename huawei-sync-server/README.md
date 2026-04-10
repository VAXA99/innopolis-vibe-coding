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

## Notes

- Keep `.env` private; never commit it.
- Start with `MOCK_MODE=true`.
- Later set `MOCK_MODE=false` and configure `REMOTE_SOURCE_URL`.
