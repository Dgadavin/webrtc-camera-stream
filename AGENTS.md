# Repository Guidelines

## Project Structure & Module Organization

This is a small, zero-dependency Node.js UI and proxy for MediaMTX.

- `server.js` contains the full HTTP server, route handling, static file serving, camera provisioning, and reverse proxy logic.
- `public/admin.html` is the admin page for adding, removing, and monitoring MediaMTX paths.
- `public/multiview.html` is the WebRTC/WHEP viewer for camera grids.
- `mediamtx-config.yaml` configures the external MediaMTX binary.
- `cameras.json` defines camera paths provisioned at server startup.
- `pi-publish.sh` publishes a Raspberry Pi camera stream over SRT.
- `Dockerfile` packages the Node UI server.

There is currently no dedicated `tests/` directory or asset pipeline.

## Build, Test, and Development Commands

- `npm start` or `node server.js`: start the UI server on `PORT` or `8080`.
- `mediamtx mediamtx-config.yaml`: start MediaMTX locally in a separate terminal.
- `PORT=8081 MEDIAMTX_API=localhost:9997 MEDIAMTX_WHEP=localhost:8889 npm start`: run with explicit upstream settings.
- `SERVER=<host> CAM=cam1 ./pi-publish.sh`: publish a Pi camera to a configured path.

There is no build step. The HTML files are served directly from `public/`.

## Coding Style & Naming Conventions

Use plain JavaScript and Node built-ins. Do not add npm dependencies unless there is a strong reason and the README/guide is updated. Existing code uses two-space indentation in HTML/CSS/JS blocks, double quotes in `server.js`, and compact helper functions.

Camera path names should stay compatible with the admin validation pattern: letters, numbers, `_`, and `-` only, such as `cam1` or `front-door`.

## Testing Guidelines

No automated test framework is configured. Validate changes manually:

1. Start MediaMTX with `mediamtx mediamtx-config.yaml`.
2. Start the UI with `npm start`.
3. Open `http://localhost:8080/admin` and verify add/delete/status behavior.
4. Open `http://localhost:8080/multiview?cams=cam1` and verify WHEP connection behavior when a publisher is live.

For server changes, also exercise `/api/v3/*`, `/whep/<path>`, and 404 paths.

## Commit & Pull Request Guidelines

Git history currently has only `first commit`, so no formal convention is established. Prefer short, imperative commit messages such as `Add camera provisioning config` or `Fix WHEP proxy path`.

Pull requests should include a concise summary, manual test notes, affected routes/pages, and any configuration changes. Include screenshots or screen recordings for UI changes to `public/admin.html` or `public/multiview.html`.

## Security & Configuration Tips

Keep MediaMTX host overrides constrained to `host` or `host:port` values. Do not hardcode secrets or private network details in committed files. Preserve same-origin proxy behavior so browsers do not need direct CORS access to MediaMTX.
