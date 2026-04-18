/**
 * Bridge: iOS app (Bearer API_TOKEN) -> optional real Huawei Health Kit cloud API.
 * You must register an app in Huawei Developer / AppGallery Connect and set env vars.
 */
const http = require("http");
const https = require("https");
const { URL } = require("url");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

loadEnv(path.join(__dirname, ".env"));

const PORT = Number(process.env.PORT || 8787);
const API_TOKEN = process.env.API_TOKEN || "";
const MOCK_MODE = String(process.env.MOCK_MODE || "true").toLowerCase() === "true";

const TOKEN_PATH = path.join(__dirname, ".huawei-token-store.json");
const OAUTH_AUTHORIZE = "https://oauth-login.cloud.huawei.com/oauth2/v3/authorize";
const OAUTH_TOKEN = "https://oauth-login.cloud.huawei.com/oauth2/v3/token";
const HEALTH_API_BASE = (process.env.HUAWEI_HEALTH_API_BASE || "https://health-api.cloud.huawei.com").replace(/\/+$/, "");
const DAILY_PATH = process.env.HUAWEI_DAILY_POLYMERIZE_PATH || "/healthkit/v1/sampleSet:dailyPolymerize";

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const pathname = url.pathname.replace(/\/+$/, "") || "/";

    if (req.method === "GET" && pathname === "/") {
      return sendHtml(res, 200, buildRegistrationLandingHtml());
    }

    if (req.method === "GET" && pathname === "/health") {
      return sendJson(res, 200, { ok: true, service: "huawei-sync-server" });
    }

    /** HTML-дашборд: список зарегистрированных пользователей. Защита: ?token=API_TOKEN или Authorization: Bearer */
    if (req.method === "GET" && pathname === "/admin") {
      if (!isAdminDashboardAuthorized(req, url)) {
        return sendHtml(
          res,
          401,
          `<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>Доступ</title></head>
          <body style="font-family:system-ui,sans-serif;padding:24px;max-width:520px;">
          <h2>Нужен ключ доступа</h2>
          <p>Откройте страницу с параметром <code>?token=</code> — значение из переменной <strong>API_TOKEN</strong> на Render (Environment).</p>
          <p>Пример: <code>/admin?token=ВАШ_ТОКЕН</code></p>
          </body></html>`
        );
      }
      return sendHtml(res, 200, buildAdminDashboardHtml());
    }

    /** JSON-список пользователей (без паролей) для скриптов / аналитики */
    if (req.method === "GET" && pathname === "/v1/admin/users") {
      if (!isAdminDashboardAuthorized(req, url)) {
        return sendJson(res, 401, { error: "Unauthorized", hint: "Bearer API_TOKEN or ?token=" });
      }
      const store = loadUserStore();
      const users = Object.values(store.users)
        .map((u) => ({
          email: u.email,
          fullName: u.fullName ?? null,
          createdAt: u.createdAt ?? null
        }))
        .sort((a, b) => String(b.createdAt || "").localeCompare(String(a.createdAt || "")));
      return sendJson(res, 200, { ok: true, count: users.length, users });
    }

    if (req.method === "POST" && pathname === "/v1/auth/register") {
      let body;
      try {
        body = await readJsonBody(req);
      } catch {
        return sendJson(res, 400, { ok: false, error: "Invalid JSON body" });
      }
      const out = registerUser(body);
      if (!out.ok) {
        return sendJson(res, 400, out);
      }
      const supabase = await syncRegistrationToSupabase(out.user);
      return sendJson(res, 200, { ...out, supabase });
    }

    if (req.method === "GET" && pathname === "/v1/huawei/oauth/callback") {
      return await handleOAuthCallback(res, url);
    }

    if (req.method === "GET" && pathname === "/v1/huawei/oauth/authorize-url") {
      if (!isAuthorized(req)) return sendJson(res, 401, { error: "Unauthorized" });
      return handleAuthorizeUrl(res);
    }

    if (req.method === "GET" && pathname === "/v1/huawei/oauth/status") {
      if (!isAuthorized(req)) return sendJson(res, 401, { error: "Unauthorized" });
      return handleOAuthStatus(res);
    }

    if (req.method === "GET" && pathname === "/v1/huawei/summary") {
      if (!isAuthorized(req)) {
        return sendJson(res, 401, { error: "Unauthorized" });
      }
      const payload = MOCK_MODE ? buildMockPayload() : await fetchLivePayload();
      return sendJson(res, 200, payload);
    }

    /** App → Render: save daily health rows (same Bearer API_TOKEN as Huawei). No Supabase. */
    if (req.method === "POST" && pathname === "/v1/health/daily-upload") {
      if (!isAuthorized(req)) {
        return sendJson(res, 401, { error: "Unauthorized" });
      }
      let body;
      try {
        body = await readJsonBody(req);
      } catch {
        return sendJson(res, 400, { error: "Invalid JSON body" });
      }
      const out = handleHealthDailyUpload(body);
      return sendJson(res, out.ok ? 200 : 400, out);
    }

    sendJson(res, 404, { error: "Not found" });
  } catch (error) {
    sendJson(res, 500, { error: "Internal error", message: String(error?.message || error) });
  }
});

server.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`huawei-sync-server listening on :${PORT} MOCK_MODE=${MOCK_MODE}`);
});

function isAuthorized(req) {
  if (!API_TOKEN) return true;
  const raw = req.headers.authorization || "";
  const token = raw.startsWith("Bearer ") ? raw.slice("Bearer ".length).trim() : "";
  return token && token === API_TOKEN;
}

/** Дашборд и /v1/admin/users: тот же секрет, что и для Huawei API — query ?token= или Bearer */
function isAdminDashboardAuthorized(req, url) {
  if (!API_TOKEN) return true;
  const q = url.searchParams.get("token") || "";
  const raw = req.headers.authorization || "";
  const bearer = raw.startsWith("Bearer ") ? raw.slice("Bearer ".length).trim() : "";
  return (q && q === API_TOKEN) || (bearer && bearer === API_TOKEN);
}

function sendJson(res, statusCode, body) {
  const data = JSON.stringify(body);
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store"
  });
  res.end(data);
}

function sendHtml(res, statusCode, html) {
  res.writeHead(statusCode, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
  res.end(html);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString("utf8");
        if (!raw.trim()) return resolve(null);
        resolve(JSON.parse(raw));
      } catch (e) {
        reject(e);
      }
    });
    req.on("error", reject);
  });
}

const HEALTH_UPLOAD_PATH = process.env.HEALTH_UPLOAD_STORE_PATH
  ? path.resolve(process.env.HEALTH_UPLOAD_STORE_PATH)
  : path.join(__dirname, ".health-upload-store.json");
const USER_STORE_PATH = process.env.USER_STORE_PATH
  ? path.resolve(process.env.USER_STORE_PATH)
  : path.join(__dirname, ".user-store.json");

function loadHealthUploadStore() {
  try {
    const data = fs.readFileSync(HEALTH_UPLOAD_PATH, "utf8");
    const o = JSON.parse(data);
    if (o && typeof o.devices === "object") return o;
  } catch {
    /* empty */
  }
  return { devices: {} };
}

function loadUserStore() {
  try {
    const data = fs.readFileSync(USER_STORE_PATH, "utf8");
    const o = JSON.parse(data);
    if (o && typeof o.users === "object") return o;
  } catch {
    /* empty */
  }
  return { users: {} };
}

function saveUserStore(store) {
  fs.writeFileSync(USER_STORE_PATH, JSON.stringify(store, null, 2), "utf8");
}

function normalizeEmail(email) {
  return String(email || "").trim().toLowerCase();
}

function registerUser(body) {
  if (!body || typeof body !== "object") {
    return { ok: false, error: "Expected JSON object" };
  }
  const email = normalizeEmail(body.email);
  const password = String(body.password || "");
  const fullName = String(body.fullName || "").trim().slice(0, 100);

  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return { ok: false, error: "Invalid email format" };
  }
  if (password.length < 6) {
    return { ok: false, error: "Password must be at least 6 characters" };
  }

  const store = loadUserStore();
  if (store.users[email]) {
    return { ok: false, error: "User already exists" };
  }

  const salt = crypto.randomBytes(16).toString("hex");
  const passwordHash = crypto.pbkdf2Sync(password, salt, 100000, 32, "sha256").toString("hex");
  const createdAt = new Date().toISOString();

  store.users[email] = {
    email,
    fullName: fullName || null,
    salt,
    passwordHash,
    createdAt
  };
  saveUserStore(store);

  return {
    ok: true,
    user: {
      email,
      fullName: fullName || null,
      createdAt
    }
  };
}

/** Дублирование регистрации в Supabase Postgres (если заданы SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY). */
let supabaseClient = null;
function getSupabaseClient() {
  const url = (process.env.SUPABASE_URL || "").trim();
  const key = (process.env.SUPABASE_SERVICE_ROLE_KEY || "").trim();
  if (!url || !key) return null;
  if (!supabaseClient) {
    // eslint-disable-next-line global-require
    const { createClient } = require("@supabase/supabase-js");
    supabaseClient = createClient(url, key, {
      auth: { persistSession: false, autoRefreshToken: false }
    });
  }
  return supabaseClient;
}

async function syncRegistrationToSupabase(user) {
  const sb = getSupabaseClient();
  if (!sb) {
    return { synced: false, skipped: true, reason: "Supabase env not set" };
  }
  try {
    const row = {
      email: user.email,
      full_name: user.fullName ?? null,
      registered_at: user.createdAt || new Date().toISOString()
    };
    const { error } = await sb.from("app_registrations").upsert(row, {
      onConflict: "email"
    });
    if (error) {
      // eslint-disable-next-line no-console
      console.warn("Supabase upsert:", error.message);
      return { synced: false, error: error.message };
    }
    return { synced: true };
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn("Supabase sync:", e);
    return { synced: false, error: String(e?.message || e) };
  }
}

function buildAdminDashboardHtml() {
  const store = loadUserStore();
  const list = Object.values(store.users).sort((a, b) =>
    String(b.createdAt || "").localeCompare(String(a.createdAt || ""))
  );
  const rows = list
    .map(
      (u) =>
        `<tr><td>${escapeHtml(u.email)}</td><td>${escapeHtml(u.fullName || "—")}</td><td>${escapeHtml(
          String(u.createdAt || "")
        )}</td></tr>`
    )
    .join("");
  return `<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Smart Alarm — пользователи</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 0; padding: 24px; background: #0f1419; color: #e8eaed; }
    h1 { font-size: 1.25rem; margin: 0 0 8px; }
    p.note { color: #9aa0a6; font-size: 13px; margin: 0 0 20px; max-width: 640px; }
    table { border-collapse: collapse; width: 100%; max-width: 720px; }
    th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #30363d; }
    th { color: #8b949e; font-weight: 600; font-size: 12px; text-transform: uppercase; }
    tr:hover td { background: rgba(255,255,255,.04); }
    .count { color: #58a6ff; font-weight: 600; }
  </style>
</head>
<body>
  <h1>Зарегистрированные пользователи</h1>
  <p class="note">Пароли здесь не показываются. На бесплатном Render файлы могут обнуляться при деплое — для постоянной базы подключите PostgreSQL (Neon/Supabase) и миграцию позже.</p>
  <p class="note">Всего: <span class="count">${list.length}</span></p>
  <table>
    <thead><tr><th>Email</th><th>Имя</th><th>Регистрация (UTC)</th></tr></thead>
    <tbody>${rows || '<tr><td colspan="3">Пока никого</td></tr>'}</tbody>
  </table>
</body>
</html>`;
}

function buildRegistrationLandingHtml() {
  return `<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Smart Alarm — Регистрация</title>
  <style>
    :root { color-scheme: dark; }
    body {
      margin: 0; min-height: 100vh; display: grid; place-items: center;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: radial-gradient(circle at 20% 20%, #1f2a44, #0d111a 60%);
      color: #f2f4f8;
    }
    .card {
      width: min(92vw, 420px); padding: 22px; border-radius: 18px;
      background: rgba(16,20,32,.9); border: 1px solid rgba(255,255,255,.08);
      box-shadow: 0 20px 50px rgba(0,0,0,.35);
    }
    h1 { margin: 0 0 8px; font-size: 24px; }
    p { margin: 0 0 16px; color: #b8c0d4; font-size: 14px; }
    label { display:block; margin: 10px 0 6px; font-size: 13px; color: #d7def1; }
    input {
      width: 100%; box-sizing: border-box; padding: 11px 12px; border-radius: 10px;
      border: 1px solid #39435b; background: #0e1422; color: #f6f8ff;
    }
    button {
      width: 100%; margin-top: 14px; padding: 11px 12px; border-radius: 10px; border: 0;
      color: white; background: linear-gradient(90deg, #5a8cff, #7f6cff); font-weight: 600;
      cursor: pointer;
    }
    .hint { margin-top: 10px; font-size: 12px; color: #a9b4cf; }
    .ok, .err { margin-top: 10px; font-size: 13px; }
    .ok { color: #7fffb0; }
    .err { color: #ff9b9b; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Регистрация</h1>
    <p>Первый экран MVP на сервере. Без Supabase и без Apple ID.</p>
    <form id="reg-form">
      <label for="fullName">Имя</label>
      <input id="fullName" type="text" placeholder="Иван Иванов" maxlength="100" />
      <label for="email">Email</label>
      <input id="email" type="email" required placeholder="name@example.com" />
      <label for="password">Пароль</label>
      <input id="password" type="password" required minlength="6" placeholder="Минимум 6 символов" />
      <button type="submit">Создать аккаунт</button>
    </form>
    <div id="result" class="hint">Данные сохраняются в локальное хранилище сервера.</div>
  </div>
  <script>
    const form = document.getElementById("reg-form");
    const result = document.getElementById("result");
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      result.className = "hint";
      result.textContent = "Отправка...";
      const payload = {
        fullName: document.getElementById("fullName").value,
        email: document.getElementById("email").value,
        password: document.getElementById("password").value
      };
      try {
        const res = await fetch("/v1/auth/register", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload)
        });
        const json = await res.json();
        if (json.ok) {
          result.className = "ok";
          result.textContent = "Готово: аккаунт создан для " + (json.user?.email || payload.email);
          form.reset();
        } else {
          result.className = "err";
          result.textContent = json.error || "Ошибка регистрации";
        }
      } catch (err) {
        result.className = "err";
        result.textContent = "Сеть недоступна: " + String(err?.message || err);
      }
    });
  </script>
</body>
</html>`;
}

function saveHealthUploadStore(store) {
  fs.writeFileSync(HEALTH_UPLOAD_PATH, JSON.stringify(store, null, 2), "utf8");
}

/**
 * Body: { deviceId: string, records: [{ date_iso, steps?, active_energy_kcal?, sleep_hours? }] }
 * Disk is ephemeral on Render unless you attach a disk or use a real DB.
 */
function handleHealthDailyUpload(body) {
  if (!body || typeof body !== "object") {
    return { ok: false, error: "Expected JSON object" };
  }
  const deviceId = typeof body.deviceId === "string" ? body.deviceId.trim() : "";
  if (!deviceId || deviceId.length > 128) {
    return { ok: false, error: "deviceId required (string, max 128)" };
  }
  const records = body.records;
  if (!Array.isArray(records) || records.length === 0) {
    return { ok: false, error: "records must be a non-empty array" };
  }
  if (records.length > 400) {
    return { ok: false, error: "Too many records (max 400)" };
  }

  const store = loadHealthUploadStore();
  if (!store.devices[deviceId]) {
    store.devices[deviceId] = { updatedAt: null, byDate: {} };
  }
  const bucket = store.devices[deviceId];
  let merged = 0;
  for (const r of records) {
    const dateIso = typeof r.date_iso === "string" ? r.date_iso.trim().slice(0, 10) : "";
    if (!/^\d{4}-\d{2}-\d{2}$/.test(dateIso)) continue;
    const row = {
      date_iso: dateIso,
      steps: typeof r.steps === "number" && Number.isFinite(r.steps) ? Math.round(r.steps) : null,
      active_energy_kcal:
        typeof r.active_energy_kcal === "number" && Number.isFinite(r.active_energy_kcal)
          ? r.active_energy_kcal
          : null,
      sleep_hours:
        typeof r.sleep_hours === "number" && Number.isFinite(r.sleep_hours) ? r.sleep_hours : null,
      savedAt: new Date().toISOString()
    };
    bucket.byDate[dateIso] = row;
    merged += 1;
  }
  bucket.updatedAt = new Date().toISOString();
  saveHealthUploadStore(store);
  return { ok: true, deviceId, merged, totalDates: Object.keys(bucket.byDate).length };
}

function buildMockPayload() {
  const now = new Date();
  const history = [];
  for (let i = 6; i >= 0; i -= 1) {
    const day = new Date(now);
    day.setDate(now.getDate() - i);
    history.push({
      date: isoDay(day),
      steps: 5200 + (6 - i) * 700,
      activeEnergyKcal: 320 + (6 - i) * 35,
      sleepLastNightHours: Number((6.1 + ((6 - i) % 4) * 0.4).toFixed(1))
    });
  }
  const latest = history[history.length - 1];
  return {
    dataSource: "mock",
    mock: true,
    latest,
    summary: latest,
    history
  };
}

async function fetchLivePayload() {
  if (process.env.HUAWEI_CLIENT_ID && process.env.HUAWEI_CLIENT_SECRET && process.env.HUAWEI_REDIRECT_URI) {
    const store = loadTokenStore();
    if (store.refresh_token || store.access_token) {
      await ensureFreshHuaweiAccessToken(store);
      const mapped = await fetchHuaweiDailyAsHistory(store.access_token);
      if (mapped && mapped.length) {
        const latest = mapped[mapped.length - 1];
        return {
          dataSource: "huawei_cloud",
          mock: false,
          latest,
          summary: latest,
          history: mapped
        };
      }
    }
  }

  const remote = process.env.REMOTE_SOURCE_URL || "";
  if (remote) {
    const remoteToken = process.env.REMOTE_SOURCE_TOKEN || "";
    const { status, json } = await httpRequestJson("GET", remote, {
      Authorization: remoteToken ? `Bearer ${remoteToken}` : undefined
    });
    if (status >= 200 && status < 300 && json && typeof json === "object") {
      return { ...json, dataSource: json.dataSource || "remote", mock: false };
    }
    throw new Error(`REMOTE_SOURCE_URL HTTP ${status}`);
  }

  throw new Error(
    "Live mode: link Huawei OAuth first (see README), or set REMOTE_SOURCE_URL, or set MOCK_MODE=true."
  );
}

function loadTokenStore() {
  try {
    const raw = fs.readFileSync(TOKEN_PATH, "utf8");
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

function saveTokenStore(obj) {
  fs.writeFileSync(TOKEN_PATH, JSON.stringify(obj, null, 2), "utf8");
}

function makeOAuthState() {
  const secret = process.env.HUAWEI_CLIENT_SECRET || "";
  const payload = JSON.stringify({ exp: Date.now() + 600000, n: crypto.randomBytes(12).toString("hex") });
  const b = Buffer.from(payload).toString("base64url");
  const sig = crypto.createHmac("sha256", secret).update(b).digest("base64url");
  return `${b}.${sig}`;
}

function verifyOAuthState(state) {
  try {
    const secret = process.env.HUAWEI_CLIENT_SECRET || "";
    const [b, sig] = String(state).split(".");
    if (!b || !sig) return false;
    const expected = crypto.createHmac("sha256", secret).update(b).digest("base64url");
    if (expected !== sig) return false;
    const obj = JSON.parse(Buffer.from(b, "base64url").toString("utf8"));
    return obj.exp > Date.now();
  } catch {
    return false;
  }
}

function handleAuthorizeUrl(res) {
  const clientId = process.env.HUAWEI_CLIENT_ID || "";
  const redirect = encodeURIComponent(process.env.HUAWEI_REDIRECT_URI || "");
  const scopes = encodeURIComponent(
    process.env.HUAWEI_OAUTH_SCOPES ||
      "openid profile https://www.huawei.com/healthkit/step.read https://www.huawei.com/healthkit/calories.read https://www.huawei.com/healthkit/sleep.read"
  );
  if (!clientId || !process.env.HUAWEI_REDIRECT_URI) {
    return sendJson(res, 400, {
      error: "Missing HUAWEI_CLIENT_ID or HUAWEI_REDIRECT_URI in environment."
    });
  }
  const state = makeOAuthState();
  const url = `${OAUTH_AUTHORIZE}?client_id=${encodeURIComponent(clientId)}&response_type=code&redirect_uri=${redirect}&scope=${scopes}&state=${encodeURIComponent(state)}`;
  return sendJson(res, 200, {
    authorizeUrl: url,
    hint: "Open this URL in a browser (phone or PC), sign in with Huawei ID, approve access. Redirect must match HUAWEI_REDIRECT_URI exactly."
  });
}

async function handleOAuthCallback(res, url) {
  const err = url.searchParams.get("error");
  if (err) {
    return sendHtml(
      res,
      400,
      `<html><body><p>Huawei OAuth error: ${escapeHtml(err)}</p></body></html>`
    );
  }
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  if (!code || !state || !verifyOAuthState(state)) {
    return sendHtml(res, 400, `<html><body><p>Invalid OAuth callback (code/state).</p></body></html>`);
  }
  const clientId = process.env.HUAWEI_CLIENT_ID;
  const clientSecret = process.env.HUAWEI_CLIENT_SECRET;
  const redirectUri = process.env.HUAWEI_REDIRECT_URI;
  if (!clientId || !clientSecret || !redirectUri) {
    return sendHtml(res, 500, `<html><body><p>Server missing Huawei client env.</p></body></html>`);
  }

  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    client_id: clientId,
    client_secret: clientSecret,
    redirect_uri: redirectUri
  });

  const tokenRes = await httpRequestForm(OAUTH_TOKEN, body.toString());
  if (tokenRes.status < 200 || tokenRes.status >= 300 || !tokenRes.json) {
    return sendHtml(
      res,
      500,
      `<html><body><p>Token exchange failed: HTTP ${tokenRes.status}</p><pre>${escapeHtml(JSON.stringify(tokenRes.json || tokenRes.text, null, 2))}</pre></body></html>`
    );
  }

  const t = tokenRes.json;
  const expiresIn = Number(t.expires_in || 3600);
  const store = {
    access_token: t.access_token,
    refresh_token: t.refresh_token || loadTokenStore().refresh_token,
    expires_at: Date.now() + expiresIn * 1000 - 120000
  };
  saveTokenStore(store);

  return sendHtml(
    res,
    200,
    `<html><body style="font-family:system-ui;padding:24px;">
      <h2>Huawei подключён</h2>
      <p>Токен сохранён на сервере. Закройте браузер и в приложении нажмите Sync now.</p>
      <p><small>Huawei linked. Close this tab and tap Sync in the app.</small></p>
    </body></html>`
  );
}

function handleOAuthStatus(res) {
  const store = loadTokenStore();
  const has = Boolean(store.access_token || store.refresh_token);
  return sendJson(res, 200, {
    mockMode: MOCK_MODE,
    huaweiLinked: has,
    accessExpiresAt: store.expires_at || null,
    hasClientConfig: Boolean(process.env.HUAWEI_CLIENT_ID && process.env.HUAWEI_REDIRECT_URI)
  });
}

async function ensureFreshHuaweiAccessToken(store) {
  const skew = Number(process.env.TOKEN_REFRESH_SKEW_SECONDS || 120) * 1000;
  if (store.access_token && store.expires_at && Date.now() < store.expires_at - skew) {
    return;
  }
  if (!store.refresh_token) return;
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: store.refresh_token,
    client_id: process.env.HUAWEI_CLIENT_ID,
    client_secret: process.env.HUAWEI_CLIENT_SECRET
  });
  const tokenRes = await httpRequestForm(OAUTH_TOKEN, body.toString());
  if (tokenRes.status < 200 || tokenRes.status >= 300 || !tokenRes.json?.access_token) {
    throw new Error(`Huawei token refresh failed: HTTP ${tokenRes.status}`);
  }
  const t = tokenRes.json;
  const expiresIn = Number(t.expires_in || 3600);
  store.access_token = t.access_token;
  if (t.refresh_token) store.refresh_token = t.refresh_token;
  store.expires_at = Date.now() + expiresIn * 1000 - 120000;
  saveTokenStore(store);
}

async function fetchHuaweiDailyAsHistory(accessToken) {
  const tz = process.env.HUAWEI_TIMEZONE || "+0000";
  const days = Math.min(14, Math.max(1, Number(process.env.HUAWEI_HISTORY_DAYS || 7)));
  const { startDay, endDay } = yyyymmddRange(days);

  const stepTypes = (process.env.HUAWEI_STEPS_DATA_TYPES || "com.huawei.continuous.steps.delta").split(",").map((s) => s.trim());
  const calTypes = (process.env.HUAWEI_CALORIES_DATA_TYPES || "com.huawei.continuous.calories.burnt").split(",").map((s) => s.trim());
  const sleepTypes = (process.env.HUAWEI_SLEEP_DATA_TYPES || "com.huawei.continuous.sleep.fragment").split(",").map((s) => s.trim());

  const [stepsBody, calBody, sleepBody] = await Promise.all([
    postPolymerize(accessToken, { dataTypes: stepTypes, startDay, endDay, timeZone: tz }),
    postPolymerize(accessToken, { dataTypes: calTypes, startDay, endDay, timeZone: tz }),
    postPolymerize(accessToken, { dataTypes: sleepTypes, startDay, endDay, timeZone: tz })
  ]);

  const byDay = new Map();
  ingestPolymerize(stepsBody, byDay, "steps");
  ingestPolymerize(calBody, byDay, "calories");
  ingestPolymerize(sleepBody, byDay, "sleep");

  const sorted = Array.from(byDay.keys()).sort();
  return sorted.map((date) => {
    const o = byDay.get(date);
    return {
      date,
      steps: o.steps != null ? Math.round(o.steps) : null,
      activeEnergyKcal: o.calories != null ? Number(o.calories.toFixed(1)) : null,
      sleepLastNightHours: o.sleepHours != null ? Number(o.sleepHours.toFixed(2)) : null,
      sleepHours: o.sleepHours != null ? Number(o.sleepHours.toFixed(2)) : null
    };
  });
}

async function postPolymerize(accessToken, bodyObj) {
  const url = `${HEALTH_API_BASE}${DAILY_PATH}`;
  const { status, json, text } = await httpRequestJson("POST", url, {
    Authorization: `Bearer ${accessToken}`,
    "Content-Type": "application/json"
  }, JSON.stringify(bodyObj));
  if (status < 200 || status >= 300) {
    // eslint-disable-next-line no-console
    console.warn("Huawei polymerize warn", url, status, text?.slice(0, 500));
  }
  return json || {};
}

function ingestPolymerize(apiBody, byDay, kind) {
  const list =
    apiBody.dailyDataList ||
    apiBody.dailyPolymerizeDataList ||
    apiBody.dataList ||
    apiBody.sampleSet ||
    [];
  if (!Array.isArray(list)) return;
  for (const row of list) {
    const raw = row.startDay || row.endDay || row.day;
    const date = normalizeHuaweiDay(raw);
    if (!date) continue;
    if (!byDay.has(date)) byDay.set(date, {});
    const slot = byDay.get(date);
    if (kind === "steps") {
      const v = extractStepsFromRow(row);
      if (v != null) slot.steps = (slot.steps || 0) + v;
    } else if (kind === "calories") {
      const v = extractCaloriesFromRow(row);
      if (v != null) slot.calories = (slot.calories || 0) + v;
    } else if (kind === "sleep") {
      const v = extractSleepHoursFromRow(row);
      if (v != null) slot.sleepHours = (slot.sleepHours || 0) + v;
    }
  }
}

function normalizeHuaweiDay(raw) {
  if (!raw) return null;
  const s = String(raw).replace(/\D/g, "");
  if (s.length === 8) return `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}`;
  if (/^\d{4}-\d{2}-\d{2}$/.test(raw)) return raw;
  return null;
}

function extractStepsFromRow(row) {
  const fromCollectors = walkDataCollectors(row, (type, points) => {
    if (!/step/i.test(type)) return null;
    return sumNumericPoints(points);
  });
  if (fromCollectors != null) return fromCollectors;
  if (typeof row.totalSteps === "number") return row.totalSteps;
  if (typeof row.steps === "number") return row.steps;
  return null;
}

function extractCaloriesFromRow(row) {
  return walkDataCollectors(row, (type, points) => {
    if (!/(calor|active|energy)/i.test(type)) return null;
    return sumNumericPoints(points);
  });
}

function extractSleepHoursFromRow(row) {
  const minutes = walkDataCollectors(row, (type, points) => {
    if (!/sleep/i.test(type)) return null;
    return sumSleepMinutes(points);
  });
  return minutes != null ? minutes / 60 : null;
}

function walkDataCollectors(row, fn) {
  const collectors = row.dataCollectorDatas || row.dataCollectors || row.collectors || [];
  if (!Array.isArray(collectors)) return null;
  let acc = null;
  for (const c of collectors) {
    const type = String(c.dataTypeName || c.dataType || c.name || "");
    const points = c.samplePoints || c.sampleSet || c.points || [];
    const v = fn(type, points);
    if (v != null) acc = (acc || 0) + v;
  }
  return acc;
}

function sumNumericPoints(points) {
  if (!Array.isArray(points)) return null;
  let s = 0;
  let any = false;
  for (const p of points) {
    const n = pickNumber(p);
    if (n != null) {
      s += n;
      any = true;
    }
  }
  return any ? s : null;
}

function sumSleepMinutes(points) {
  if (!Array.isArray(points)) return null;
  let minutes = 0;
  let any = false;
  for (const p of points) {
    const start = p.startTime || p.start;
    const end = p.endTime || p.end;
    if (start != null && end != null) {
      const a = Number(start);
      const b = Number(end);
      if (!Number.isNaN(a) && !Number.isNaN(b) && b > a) {
        minutes += (b - a) / 60_000_000_000;
        any = true;
      }
    } else if (p.value != null || p.fieldValue != null) {
      const n = pickNumber(p);
      if (n != null) {
        minutes += n;
        any = true;
      }
    }
  }
  return any ? minutes : null;
}

function pickNumber(p) {
  if (typeof p === "number") return p;
  if (p == null) return null;
  const keys = ["value", "fieldValue", "floatValue", "intValue", "doubleValue", "scalar"];
  for (const k of keys) {
    if (typeof p[k] === "number") return p[k];
  }
  return null;
}

function yyyymmddRange(numDays) {
  const end = new Date();
  const start = new Date();
  start.setDate(start.getDate() - (numDays - 1));
  return { startDay: toYYYYMMDD(start), endDay: toYYYYMMDD(end) };
}

function toYYYYMMDD(d) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}${m}${day}`;
}

function isoDay(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function httpRequestForm(urlStr, formBody) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlStr);
    const opts = {
      method: "POST",
      hostname: u.hostname,
      path: u.pathname + u.search,
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "Content-Length": Buffer.byteLength(formBody)
      }
    };
    const req = https.request(opts, (res) => {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => {
        let json = null;
        try {
          json = JSON.parse(data);
        } catch {
          /* ignore */
        }
        resolve({ status: res.statusCode || 0, json, text: data });
      });
    });
    req.on("error", reject);
    req.write(formBody);
    req.end();
  });
}

function httpRequestJson(method, urlStr, headers, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlStr);
    const h = { ...headers };
    const payload = body != null ? Buffer.from(body, "utf8") : null;
    if (payload) h["Content-Length"] = String(payload.length);
    const opts = {
      method,
      hostname: u.hostname,
      path: u.pathname + u.search,
      headers: h
    };
    const req = https.request(opts, (res) => {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => {
        let json = null;
        try {
          json = JSON.parse(data);
        } catch {
          /* ignore */
        }
        resolve({ status: res.statusCode || 0, json, text: data });
      });
    });
    req.on("error", reject);
    if (payload) req.write(payload);
    req.end();
  });
}

function loadEnv(filePath) {
  if (!fs.existsSync(filePath)) return;
  const text = fs.readFileSync(filePath, "utf8");
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const idx = line.indexOf("=");
    if (idx <= 0) continue;
    const key = line.slice(0, idx).trim();
    const value = line.slice(idx + 1).trim();
    if (!(key in process.env)) {
      process.env[key] = value;
    }
  }
}
