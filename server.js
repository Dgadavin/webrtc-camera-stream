#!/usr/bin/env node
/*
 * mediamtx-ui — zero-dependency Node HTTP server.
 *
 * Serves the admin and multiview pages from ./public, and reverse-proxies
 * MediaMTX's control API and WHEP endpoint so the browser can talk to a
 * single same-origin server (no CORS, no host-input fields in the UI).
 *
 *   /admin           -> public/admin.html
 *   /multiview       -> public/multiview.html
 *   /api/v3/...      -> http://<MEDIAMTX_API>/v3/...     (default :9997)
 *   /whep/<path>     -> http://<MEDIAMTX_WHEP>/<path>/whep (default :8889)
 *
 * Configure via env vars: PORT, MEDIAMTX_API, MEDIAMTX_WHEP.
 */

const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = parseInt(process.env.PORT || "8080", 10);
const MEDIAMTX_API = process.env.MEDIAMTX_API || "localhost:9997";
const MEDIAMTX_WHEP = process.env.MEDIAMTX_WHEP || "localhost:8889";
const CAMERAS_FILE = process.env.CAMERAS_FILE || path.join(__dirname, "cameras.json");

const PUBLIC_DIR = path.join(__dirname, "public");

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
};

function sendFile(res, filePath) {
  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(err.code === "ENOENT" ? 404 : 500, { "Content-Type": "text/plain" });
      res.end(err.code === "ENOENT" ? "Not found" : "Internal error");
      return;
    }
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, { "Content-Type": MIME[ext] || "application/octet-stream" });
    res.end(data);
  });
}

function proxy(req, res, targetHost, targetPath) {
  const [host, portStr] = targetHost.split(":");
  const port = parseInt(portStr || "80", 10);

  // Forward headers but rewrite Host to the upstream so MediaMTX virtual-hosts correctly.
  const headers = { ...req.headers, host: targetHost };
  delete headers["connection"];

  const upstream = http.request(
    { host, port, path: targetPath, method: req.method, headers },
    (upRes) => {
      res.writeHead(upRes.statusCode, upRes.headers);
      upRes.pipe(res);
    }
  );

  upstream.on("error", (err) => {
    res.writeHead(502, { "Content-Type": "text/plain" });
    res.end(`Upstream error contacting ${targetHost}: ${err.message}`);
  });

  req.pipe(upstream);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  const p = url.pathname;

  if (p === "/" || p === "/admin") {
    return sendFile(res, path.join(PUBLIC_DIR, "admin.html"));
  }
  if (p === "/multiview") {
    return sendFile(res, path.join(PUBLIC_DIR, "multiview.html"));
  }

  // /api/v3/foo -> mediamtx :9997 /v3/foo
  // Per-request override via X-MediaMTX-API header (host or host:port).
  if (p.startsWith("/api/")) {
    const override = req.headers["x-mediamtx-api"];
    const target = (override && /^[a-zA-Z0-9.\-]+(:\d+)?$/.test(override)) ? override : MEDIAMTX_API;
    return proxy(req, res, target, p.slice(4) + url.search);
  }

  // /whep/<camPath> -> mediamtx :8889 /<camPath>/whep
  // Per-request override via X-MediaMTX-WHEP header (host or host:port).
  const whep = p.match(/^\/whep\/([^/]+)\/?$/);
  if (whep) {
    const override = req.headers["x-mediamtx-whep"];
    const target = (override && /^[a-zA-Z0-9.\-]+(:\d+)?$/.test(override)) ? override : MEDIAMTX_WHEP;
    return proxy(req, res, target, `/${whep[1]}/whep${url.search}`);
  }

  // Anything else under /static/ is served from public/.
  if (p.startsWith("/static/")) {
    const safe = path.normalize(p.slice("/static/".length)).replace(/^(\.\.[/\\])+/, "");
    return sendFile(res, path.join(PUBLIC_DIR, safe));
  }

  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("Not found");
});

server.listen(PORT, () => {
  console.log(`mediamtx-ui listening on http://localhost:${PORT}`);
  console.log(`  /admin       -> public/admin.html`);
  console.log(`  /multiview   -> public/multiview.html`);
  console.log(`  /api/v3/*    -> http://${MEDIAMTX_API}/v3/*`);
  console.log(`  /whep/<path> -> http://${MEDIAMTX_WHEP}/<path>/whep`);
  provisionCameras();
});

/*
 * Read CAMERAS_FILE on startup and POST each entry to MediaMTX's config API.
 * Same code path as the admin "Add" button — does not bypass the admin flow.
 * Idempotent: a 400 from /paths/add means the path already exists, which is
 * fine. Waits up to ~30s for the API to come up (matters when both processes
 * start together under Docker Compose).
 */
async function provisionCameras() {
  let cfg;
  try {
    cfg = JSON.parse(fs.readFileSync(CAMERAS_FILE, "utf8"));
  } catch (err) {
    if (err.code !== "ENOENT") console.error(`[cameras] ${CAMERAS_FILE}: ${err.message}`);
    return;
  }
  const paths = (cfg && cfg.paths) || [];
  if (!paths.length) return;

  const [host, portStr] = MEDIAMTX_API.split(":");
  const port = parseInt(portStr || "80", 10);

  const tryReq = (opts, body) => new Promise((resolve) => {
    const r = http.request({ host, port, ...opts }, (res) => {
      res.resume();
      res.on("end", () => resolve({ status: res.statusCode }));
    });
    r.on("error", (e) => resolve({ error: e }));
    if (body) r.write(body);
    r.end();
  });

  for (let i = 1; i <= 30; i++) {
    const r = await tryReq({ path: "/v3/config/global/get", method: "GET" });
    if (!r.error && r.status === 200) break;
    if (i === 1) console.log(`[cameras] waiting for MediaMTX at ${MEDIAMTX_API}…`);
    if (i === 30) { console.error(`[cameras] MediaMTX unreachable — skipping provisioning`); return; }
    await new Promise((r) => setTimeout(r, 1000));
  }

  for (const p of paths) {
    if (!p.name) continue;
    const body = JSON.stringify({ source: p.source || "publisher" });
    const r = await tryReq({
      path: `/v3/config/paths/add/${encodeURIComponent(p.name)}`,
      method: "POST",
      headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
    }, body);
    if (r.error) console.warn(`[cameras] '${p.name}': ${r.error.message}`);
    else if (r.status === 200) console.log(`[cameras] added '${p.name}'`);
    else if (r.status === 400) console.log(`[cameras] '${p.name}' already exists`);
    else console.warn(`[cameras] '${p.name}': HTTP ${r.status}`);
  }
}
