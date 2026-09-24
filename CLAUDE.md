# CLAUDE.md: Multicam Studio (palermostest25 fork)

Read this whole file before doing anything in this repository.

## Who owns what

- **This repo** (`palermostest25/multicam-studio`, remote `origin`) is the owner's fork and the **canonical, "best" version**. It is deployed to the owner's server through Arcane from the Docker image this repo builds.
- **Upstream** is the owner's friend's project, `ZeusyBoy99/multicam-studio` (public, default branch `main`). The friend keeps developing it with his own AI agent. We do **not** send pull requests upstream and we do **not** wait for him to merge anything.
- Our job: keep pulling the friend's new work into this fork and keep this fork's extras working on top of it:
  1. Windows support (running from source)
  2. Docker / server mode (for Arcane)
  3. The stdlib-only UI demo on the `ui-demo` branch

## Standing permissions and preferences (from the owner)

- **Commit and push directly to `main`.** Don't create feature branches or `claude/...` branches, and don't open PRs for this work, even if the session was started on another branch. The owner explicitly asked for this.
- Also keep **`ui-demo`** up to date (see below). Push to it directly too.
- Never force-push `main` or `ui-demo`. Use merge commits, never rebase.
- Don't include model names or IDs in commits or files.
- **No env files, ever.** Never create or reference `.env` or `.env.example` files, and never use `${VAR}` interpolation in compose files. Write every compose value literally in the compose file itself. The `environment:` block with literal values is fine, since it's how the image is configured.

## "Go": the upstream sync routine

When the owner says **"go"**, "sync", "pull from upstream", "he updated", or similar, do all of the following without asking for confirmation. Only stop to ask if a conflict forces a real product decision, i.e. both sides changed the same behaviour and keeping both is impossible.

```sh
cd <repo>
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream https://github.com/ZeusyBoy99/multicam-studio
git fetch origin && git fetch upstream
git checkout main && git pull --ff-only origin main
git log --oneline main..upstream/main      # what's new; if empty, report "already up to date" and stop
git merge --no-ff upstream/main            # merge commit, never rebase
```

1. **Resolve conflicts, keeping both sides.** Take upstream's new features and logic, then re-apply our invariants (next section) on top. The usual hot spots are `server.py` and `web/app.js`. `app.js` is written as very long minified-style lines, so conflicts there are whole-line: take upstream's line and re-apply our wording and path changes. If upstream ever adds its own `CLAUDE.md`, keep ours and merge in anything useful from theirs.
2. **Audit upstream's new code** against the invariants: new files, new `subprocess` calls, new `read_text`/`write_text`/`open`, new Popen/kill logic, new user-facing text mentioning "Mac", new modules imported by `server.py`, and new dependencies in `requirements.txt`. Fix whatever breaks Windows, Docker or the demo.
3. **Validate** (see Testing). Fix failures before pushing.
4. **Commit** the merge with a clear message listing what came from upstream and what was fixed, then `git push origin main`.
5. **Check the Docker CI run** for the new `main` commit (GitHub Actions workflow "Docker image"). If it fails, read the job logs, fix, and push again. It isn't done until it's green.
6. **Update `ui-demo`:** `git checkout ui-demo && git pull --ff-only origin ui-demo && git merge --no-ff main`. Then update `demo.py` for any new endpoints, response fields or engine functions the UI now uses (see Demo). Run the demo checks, commit, `git push origin ui-demo`, and return to `main`.
7. **Report** in a few lines: what upstream added, which conflicts and fixes there were, test results, CI status, and anything not verified.

## Invariants: things upstream doesn't have that must survive every merge

### Cross-platform (Windows) in `server.py`
- `WINDOWS = os.name == 'nt'`. Import `msvcrt` on Windows and `fcntl` elsewhere; never import `fcntl` unconditionally.
- `InstanceLock`: on Windows it locks a separate `server.lock.guard` file with `msvcrt.locking`, so `server.lock` stays readable. It uses `fcntl.flock` elsewhere.
- Workers start with `**spawn_options()` (`CREATE_NEW_PROCESS_GROUP` on Windows, `start_new_session=True` elsewhere) and `env=worker_environment()` (`PYTHONUTF8=1`, `PYTHONIOENCODING=utf-8`). They also pass `**UTF8` (`encoding='utf-8', errors='replace'`).
- Cancelling goes through `signal_worker(proc, 'interrupt'|'terminate'|'kill')`: Ctrl+Break then `taskkill /T /F` on Windows, `os.killpg` elsewhere. Never call `os.killpg` directly.
- Every `subprocess.run(..., text=True)` also passes `**UTF8`. Every `read_text`/`write_text`/`open` of JSON, logs or HTML passes `encoding='utf-8'`.
- Waveform endpoint: set `samples=None` before `try`, and in `finally` drop the memmap, then `unlink` inside `try/except OSError`. Windows can't delete a memory-mapped file.
- `default_media_folder()` returns `~/Videos` on Windows and `~/Movies` elsewhere. `default_roots()` lists drive letters on Windows and `/Volumes`, `/media`, `/mnt` elsewhere.
- `StudioHTTPServer.allow_reuse_address = not WINDOWS`. The port-in-use fallback also checks `WSAEADDRINUSE`.

### Cross-platform in the engine and effects
- `multicam_edit.py` imports `signal as os_signal`, because `signal` is SciPy's there. In `main()` it installs `SIGBREAK -> default_int_handler`, uses `TemporaryDirectory(..., ignore_cleanup_errors=True)`, and runs `del reference` after `energy_sections`. `run()` decodes as UTF-8.
- `effects.py`: `SIGBREAK -> signal.default_int_handler` in `main()`, UTF-8 for `probe`, the Popen call and the FFmpeg log.
- Error messages that mention installing FFmpeg name both `brew install ffmpeg` and `winget install Gyan.FFmpeg`.

### Server mode (Docker / Arcane) in `server.py`
- Every CLI option has a `MULTICAM_*` environment variable: `MULTICAM_HOST`, `PORT`, `STATE_DIR`, `DEFAULT_FOLDER`, `DEFAULT_OUTPUT`, `ROOTS` (os.pathsep-separated), `ALLOWED_HOSTS` (comma-separated) and `PASSWORD`.
- `--host` other than `127.0.0.1`/`localhost` means `remote=True`. In that case:
  - Any `Host` header is accepted unless the `ALLOWED_HOSTS` allowlist is set.
  - `Origin` must match `Host` or `X-Forwarded-Host`, over http or https.
  - Optional HTTP Basic auth via `MULTICAM_PASSWORD` (any user name).
  - `/api/shutdown` returns 409, and the UI hides `.quit-row` when `config.server_mode` is true.
  - There is no random-port fallback.
- `/api/health` is answered **before** the host, auth and token checks; the Docker healthcheck depends on it.
- Local mode (the default) keeps the original strict loopback `Host`/`Origin` checks.
- `setup_snapshot()` and `diagnostics()` include `server_mode`.

### UI (`web/`)
- `basename` and `dirname` in `app.js` handle both `/` and `\`, and `dirname` keeps `C:\` as a drive root.
- Wording stays platform-neutral: "this computer", "in this browser", "your machine". Never "this Mac". Upstream keeps reintroducing "on this Mac" in draft and autosave strings, so check every merge.
- The runtime line shows `macOS` only when `platform === 'Darwin'`.

### Docker and deployment files (ours only)
- `Dockerfile`: `python:3.12-slim` plus Debian `ffmpeg` (which includes libx264), `pip install -r requirements.txt`, `COPY *.py ./` (every module, so new upstream files are included), `COPY web ./web`, a world-writable `/state`, `MULTICAM_*` defaults (`/media/recordings`, `/media/exports`, roots `/media`), and a healthcheck on `/api/health`. If upstream adds non-Python runtime files (for example a new data folder), add them to the Dockerfile.
- `.dockerignore`, and `docker-compose.yml`: literal values, no `.env`, no `${}`. It matches the owner's Arcane setup below (port 4067, `/opt/Docker/appdata/multicam-studio/...`) plus `build: .` as a fallback.
- `.github/workflows/docker.yml` builds `linux/amd64,linux/arm64` and pushes `ghcr.io/palermostest25/multicam-studio` (`latest` on `main`, semver on `v*` tags, sha). Only pushes to `main` and tags trigger it.
- `Start Multicam Studio.bat`: the Windows launcher (venv plus pip on first run, then `server.py --open`). It uses CRLF line endings and `goto` labels rather than parenthesised blocks.
- README sections "Run on Windows" and "Run in Docker (Arcane, Portainer, Compose)". Keep them when upstream edits the README.

### New requirements from upstream
If upstream adds a Python dependency, it goes in `requirements.txt` (the Docker image installs from it). Check that it installs on `python:3.12-slim` without extra system packages; if it needs any, add `apt-get` lines to the Dockerfile.

## The `ui-demo` branch

- Branch `ui-demo` = `main` plus `demo.py`, `Start Demo.bat`, a README section ("Try the interface without installing anything") and `.multicam-demo/` in `.gitignore`. It is **never merged into `main`**.
- Purpose: the owner's locked-down school laptop, which blocks venv and FFmpeg. `py demo.py --open` runs the real `server.py` and web UI on port 8766 using **only the standard library**: no NumPy, SciPy, FFmpeg or pip.
- How it works: `demo.py` subclasses `server.Studio` (fake `dependencies()`, simulated `worker()`) and `server.Handler` (fake `/api/probe`, SVG `/api/preview` and `/api/source-frame`, WAV-based `/api/waveform`). It also patches `effects.probe` with `ffprobe_json`. On first run it creates a sample project with three placeholder cameras and a generated 124 BPM WAV. Preview plans are fully simulated with a real report schema. Edit renders, clip exports, effects and batch highlights all end with `STOP_MESSAGE`.
- `demo.plan_clips` is a **pure-Python port of `highlights.plan_clips`**. When upstream changes `highlights.py`, update the port and check the two still match (compare outputs on random data with NumPy installed in a scratch venv).
- When upstream adds endpoints or response fields the UI uses, add demo equivalents. The demo must never import NumPy, SciPy or anything outside the stdlib, and must never call FFmpeg.
- Demo checks: start `python3 demo.py --state-dir <scratch> --port <p>` using the **system** python (no NumPy). Then call `/api/probe`, `/api/source-frame`, `/api/preview`, `/api/waveform` (with `target_seconds`), a plan-only `/api/jobs` job (it must complete with a report), and render, clip, effects and `/api/highlights/export` jobs (they must fail with the demo message). Optionally open it in headless Chromium and check each tab for JS errors. A CSP warning about `data:text/css` is pre-existing and harmless.

## Testing (every sync)

```sh
python3 -m py_compile server.py multicam_edit.py effects.py highlights.py
node -e "new Function(require('fs').readFileSync('web/app.js','utf8'))"
python3 -m venv /tmp/mc-venv && /tmp/mc-venv/bin/pip install -q -r requirements.txt
/tmp/mc-venv/bin/python -m unittest discover -s tests -v      # upstream's tests
```

- **Local-mode smoke test:** `python server.py --port <p> --state-dir <scratch>`. `/` returns 200 with `Host: 127.0.0.1:<p>` and 403 with `Host: evil.com`.
- **Server-mode smoke test:** `MULTICAM_PASSWORD=pw python server.py --host 0.0.0.0 --port <p> --state-dir <scratch>`. Check: `/api/health` 200 without auth, `/` 401 without auth, 200 with auth, a bad `Origin` gets 403, `/api/shutdown` gets 409, and `/api/config` has `server_mode: true`.
- Docker: if the environment can build images, `docker build .` and run the container with the smoke tests above. In the Claude Code cloud sandbox, `deb.debian.org` and GitHub release downloads are blocked, so the FFmpeg layer can't be built or installed locally and FFmpeg-dependent tests are skipped. Rely on the GitHub Actions build for the full image, and say plainly which checks were skipped.
- Windows can't be tested in the sandbox. Review Windows-specific code paths by reading them.

## Environment gotchas (cloud sandbox)

- Never `pkill -f "<pattern>"` with a pattern that also appears in the running shell command; it kills your own shell (exit 144). Use a bracket trick such as `pkill -f "port 1877[0]"`, or kill by PID.
- Docker builds need `--network host` and proxy build args. Debian mirrors are still blocked; PyPI works.
- Commit messages end with the attribution lines the harness provides.

## The owner's Arcane deployment (reference; not a file in the repo)

Server address 192.168.1.10 (LAN). The owner does **not** want a sign-in prompt: no `MULTICAM_PASSWORD`, protection comes from `MULTICAM_ALLOWED_HOSTS`. Shared host: all paths must be named volumes or under `/opt/Docker/appdata/<app>`. Port 4067. The image comes from GHCR, so it must be public or Arcane needs a ghcr.io login.

```yaml
services:
  multicam-studio:
    image: ghcr.io/palermostest25/multicam-studio:latest
    container_name: multicam-studio
    init: true
    restart: unless-stopped
    user: "1000:1000"
    ports:
      - "4067:8765"
    environment:
      # No sign-in: only requests addressed to this host are accepted.
      MULTICAM_ALLOWED_HOSTS: "192.168.1.10"
      # MULTICAM_PASSWORD: "..."   # add only if exposed beyond the home network
    volumes:
      - /opt/Docker/appdata/multicam-studio/recordings:/media/recordings
      - /opt/Docker/appdata/multicam-studio/exports:/media/exports
      - /opt/Docker/appdata/multicam-studio/state:/state
```

Host setup: `sudo mkdir -p /opt/Docker/appdata/multicam-studio/{recordings,exports,state} && sudo chown -R 1000:1000 /opt/Docker/appdata/multicam-studio`. If a change affects deployment (new env vars, volumes, ports), tell the owner exactly what to change in this compose.

## History (for context)

1. Added Windows support, server mode, Docker, compose, the GHCR workflow and the Windows launcher; pushed to `main`. Later removed `.env.example` and all `${}` interpolation at the owner's request.
2. Created `ui-demo` with the stdlib-only demo.
3. Merged upstream 1.2.0 (batch energetic highlights, new `highlights.py`). The conflicts were in `server.py` (waveform endpoint) and `app.js` (draft strings). The Dockerfile switched to `COPY *.py`, and the demo got a pure-Python `plan_clips`.
4. Added this file.

## App overview (unchanged from upstream)

- `server.py`: stdlib HTTP server plus a job runner. It serves `web/`, and starts `multicam_edit.py` (edit engine) and `effects.py` (clip, effects and batch highlight exports) as subprocesses.
- `multicam_edit.py`: syncs cameras to the WAV bounce (NumPy/SciPy correlation, drift), builds the seeded shot plan and renders with FFmpeg/libx264.
- `highlights.py`: energetic clip planner (NumPy/SciPy).
- `desktop.py` and `packaging/`: the macOS app bundle (PyInstaller, signing). macOS-only; leave it as upstream has it.
- `docs/USER_GUIDE.md` and `CHANGELOG.md`: upstream-maintained.
- Run from source: `python server.py --open` (needs Python 3.10+, numpy, scipy, ffmpeg and ffprobe on PATH).
