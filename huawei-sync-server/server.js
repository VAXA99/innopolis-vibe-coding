const http = require("http");
const { URL } = require("url");
const fs = require("fs");
const path = require("path");

loadEnv(path.join(__dirname, ".env"));

const PORT = Number(process.env.PORT || 8787);
const API_TOKEN = process.env.API_TOKEN || "";
const MOCK_MODE = String(process.env.MOCK_MODE || "true").toLowerCase() === "true";

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);

    if (req.method === "GET" && url.pathname === "/health") {
      return sendJson(res, 200, { ok: true, service: "huawei-sync-server" });
    }

    if (req.method === "GET" && url.pathname === "/v1/huawei/summary") {
      if (!isAuthorized(req)) {
        return sendJson(res, 401, { error: "Unauthorized" });
      }
      const payload = MOCK_MODE ? buildMockPayload() : await fetchLivePayload();
      return sendJson(res, 200, payload);
    }

    sendJson(res, 404, { error: "Not found" });
  } catch (error) {
    sendJson(res, 500, { error: "Internal error", message: String(error?.message || error) });
  }
});

server.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`huawei-sync-server listening on :${PORT}`);
});

function isAuthorized(req) {
  if (!API_TOKEN) return true;
  const raw = req.headers.authorization || "";
  const token = raw.startsWith("Bearer ") ? raw.slice("Bearer ".length).trim() : "";
  return token && token === API_TOKEN;
}

function sendJson(res, statusCode, body) {
  const data = JSON.stringify(body);
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store"
  });
  res.end(data);
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
  return {
    latest: history[history.length - 1],
    history
  };
}

async function fetchLivePayload() {
  const remote = process.env.REMOTE_SOURCE_URL || "";
  if (!remote) {
    throw new Error("Set REMOTE_SOURCE_URL or use MOCK_MODE=true");
  }
  return buildMockPayload();
}

function isoDay(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
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
