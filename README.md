# mediamtx-ui

A small Node.js web UI for managing and watching cameras served by [MediaMTX](https://github.com/bluenviron/mediamtx).

It bundles two pages:

- **`/admin`** — add, remove, and monitor camera paths via the MediaMTX control API.
- **`/multiview`** — WebRTC (WHEP) viewer that renders up to four cameras in a 2×2 grid, with per-stream stats and click-to-focus.

The Node server has **zero npm dependencies** — it uses only the built-in `http` module — and also reverse-proxies the MediaMTX API and WHEP endpoint so the browser only ever talks to one origin.

---

## Requirements

- **Node.js ≥ 18** (anything with the global `URL` class).
- A running **MediaMTX** instance (any recent version with the `v3` API). This repo includes a minimal [`mediamtx-config.yaml`](mediamtx-config.yaml) you can use.

## Quickstart

In one terminal, start MediaMTX with the bundled config:

```sh
mediamtx mediamtx-config.yaml
```

In another, start the UI server:

```sh
npm start
```

Then open:

- <http://localhost:8080/admin> — add a camera path (e.g. name `cam1`, source `publisher`).
- <http://localhost:8080/multiview> — view cams `cam1..cam4` in a grid.
- <http://localhost:8080/multiview?cams=cam1,cam2> — view a custom set of cams.

## Publishing a camera from a Raspberry Pi

Add a path in the admin UI with source `publisher`, then on the Pi run:

```sh
rpicam-vid -t 0 \
  --width 1280 --height 720 --framerate 30 \
  --codec h264 --profile baseline --inline --intra 30 \
  --libav-format rtsp \
  -o rtsp://<server>:8554/<path-name>
```

The admin page will flip the path to **LIVE** once the publisher connects.

## Configuration

The server is configured via env vars:

| Variable        | Default          | Meaning                                                   |
| --------------- | ---------------- | --------------------------------------------------------- |
| `PORT`          | `8080`           | Port the UI server listens on                             |
| `MEDIAMTX_API`  | `localhost:9997` | `host:port` of MediaMTX's HTTP control API                |
| `MEDIAMTX_WHEP` | `localhost:8889` | `host:port` of MediaMTX's WebRTC / WHEP endpoint          |

Example: run the UI on a different machine from MediaMTX:

```sh
PORT=80 MEDIAMTX_API=192.168.0.147:9997 MEDIAMTX_WHEP=192.168.0.147:8889 npm start
```

## How it fits together

```
                                 ┌─────────────────────────────┐
 Browser  ───────────────────►   │  Node server (this repo)    │
  /admin                         │  • serves public/*.html     │
  /multiview                     │  • proxies API + WHEP       │
  /api/v3/*                      └──────────────┬──────────────┘
  /whep/<path>                                  │
                                                ▼
                                 ┌─────────────────────────────┐
                                 │  MediaMTX                   │
                                 │  :9997 (control API)        │
                                 │  :8889 (WebRTC / WHEP)      │
                                 │  :8554 (RTSP — publishers)  │
                                 └─────────────────────────────┘
                                                ▲
                                                │  publishes via RTSP
                                 ┌──────────────┴──────────────┐
                                 │  Raspberry Pi (rpicam-vid)  │
                                 └─────────────────────────────┘
```

The UI never talks to MediaMTX directly. Everything is same-origin through the Node proxy, so there is no CORS configuration and no host fields to fill in.

## Project layout

```
.
├── server.js              # zero-dep HTTP server + reverse proxy
├── package.json
├── mediamtx-config.yaml   # MediaMTX config — paths populated at runtime
├── public/
│   ├── admin.html         # /admin
│   └── multiview.html     # /multiview
├── README.md
└── CLAUDE.md              # notes for Claude Code
```
