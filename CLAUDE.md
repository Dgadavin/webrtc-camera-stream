# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A small Node.js web UI for an external **MediaMTX** media-server binary. Two pages — `/admin` and `/multiview` — are served by a zero-dependency Node HTTP server that also reverse-proxies MediaMTX's control API and WHEP endpoint.

Files of substance:

- [server.js](server.js) — the entire server (routing + reverse proxy), uses only Node built-ins
- [public/admin.html](public/admin.html) — adds / removes / monitors camera paths via the proxied control API
- [public/multiview.html](public/multiview.html) — WebRTC/WHEP viewer in a 2×2 grid
- [mediamtx-config.yaml](mediamtx-config.yaml) — MediaMTX server config (consumed by the `mediamtx` binary, **not** by this repo's Node server)
- [package.json](package.json) — only `"start": "node server.js"`. **No dependencies are installed; do not `npm install` packages without a reason.** The point of this codebase is to stay dep-free.

## Running

```sh
mediamtx mediamtx-config.yaml   # in one terminal
npm start                        # in another (or: node server.js)
```

Then visit <http://localhost:8080/admin>. Env vars `PORT`, `MEDIAMTX_API` (default `localhost:9997`), `MEDIAMTX_WHEP` (default `localhost:8889`) override defaults — see the README for details.

There is no build step, no test suite, no linter. "Testing" a change means running the server, opening the page, and clicking through.

## Architecture

### Server ([server.js](server.js))

A single `http.createServer` handler dispatches on `url.pathname`:

| Path             | Behavior                                                                              |
| ---------------- | ------------------------------------------------------------------------------------- |
| `/` or `/admin`  | serves `public/admin.html`                                                            |
| `/multiview`     | serves `public/multiview.html`                                                        |
| `/api/v3/...`    | proxies to `http://<MEDIAMTX_API>/v3/...` (strips the `/api` prefix)                  |
| `/whep/<path>`   | proxies to `http://<MEDIAMTX_WHEP>/<path>/whep` (rewrites segment order)              |
| `/static/<file>` | serves arbitrary files from `public/` (currently unused — provided as escape hatch)   |
| anything else    | 404                                                                                   |

The `proxy()` function streams the request body up and the response body back via `req.pipe(upstream)` / `upRes.pipe(res)`. It rewrites the `Host` header to the upstream's `host:port` (MediaMTX is strict about this) and drops `Connection`. Status code and all other response headers pass through unchanged — this matters for WHEP, which sets `Content-Type: application/sdp` and a `Location` header on success.

### Frontend ([public/admin.html](public/admin.html), [public/multiview.html](public/multiview.html))

Both pages are self-contained: inline CSS, inline JS, no bundler, no external scripts. Edit in place.

**admin.html** is a thin client over four MediaMTX v3 endpoints (all reached via `/api/v3/`):

- `GET /config/paths/list` — configured paths (persisted state)
- `GET /paths/list` — active paths (used to derive LIVE/idle status and reader counts)
- `POST /config/paths/add/{name}` body `{ source }` — add a path
- `DELETE /config/paths/delete/{name}` — remove a path

The page polls both list endpoints every 3 s and joins them by `name`.

**multiview.html** is a WHEP client. For each grid cell it:

1. Creates an `RTCPeerConnection` with `recvonly` audio + video transceivers
2. Generates an SDP offer and waits for ICE gathering to complete (or 2 s timeout)
3. POSTs the offer to `/whep/<path>` (proxied to MediaMTX :8889) with `Content-Type: application/sdp`
4. Sets the returned SDP as the remote answer

Camera list is hard-coded as `cam1..cam4` but overridable via `?cams=a,b,c,d`. The admin page's "View" button uses this to open a single-camera view: `/multiview?cams=<name>`.

Per-cell stats (bitrate, fps, jitter, packet loss, resolution) come from `RTCPeerConnection.getStats()` polled once per second, with `bytesReceived` diffed against the previous sample stored on the cell object.

## Conventions worth knowing

- **Path-name validation** in admin.html uses `/^[a-zA-Z0-9_-]+$/`. MediaMTX itself accepts more, but the admin URL builds don't escape further, so keep this regex if you change validation.
- **Default source** for new paths is the literal string `publisher` — MediaMTX-speak for "accept whatever publisher pushes to me", as opposed to pulling from an upstream URL. The hint block in admin.html documents the matching `rpicam-vid` invocation.
- **STUN server** `stun:stun.l.google.com:19302` appears in three places: `mediamtx-config.yaml` (`webrtcICEServers2`), and inline in both HTML files. Keep them in sync if you change it.
- **The MediaMTX config's `paths:` map is intentionally empty.** The admin page populates paths at runtime via the API. Don't hardcode paths in the YAML — it bypasses the admin flow.
- **Zero npm deps is a feature.** If you find yourself wanting a library, prefer a small inline helper. The whole server is currently ~80 lines.
