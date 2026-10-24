# CLAUDE.md: Multicam Studio (palermostest25 fork)

Read this whole file before doing anything in this repository.

## Who owns what

- **This repo** (`palermostest25/multicam-studio`, remote `origin`) is the owner's fork and the **canonical, "best" version**. It is deployed to the owner's server through Arcane from the Docker image this repo builds.
- **Upstream** is the owner's friend's project, `ZeusyBoy99/multicam-studio` (public, default branch `main`). The friend keeps developing it with his own AI agent. We do **not** send pull requests upstream and we do **not** wait for him to merge anything.
- Our job: keep pulling the friend's new work into this fork and keep this fork's extras working on top of it:
  1. Windows support (running from source)
  2. Docker / server mode (for Arcane)
  3. The stdlib-only UI demo on the `ui-demo` branch
  4. **2.0 (ours):** the native Swift macOS app in `macos/`, and the smart engine in the Python version (`music.py`, `vision.py`, `planner.py`, output formats, social clips, export subfolders). Since 2.0 our `multicam_edit.py` render/plan code has diverged a lot from upstream. On a merge, keep ours and port upstream's new behaviour into it (and into the Swift engine if it affects editing).

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
  - Sign-in via `MULTICAM_PASSWORD` (server mode only): `/login` page (`web/login.html`), `POST /api/login` sets a signed `multicam_session` cookie (HttpOnly, SameSite=Strict, 30 days; key = `state/session.key` + password, so a new password signs everyone out), `POST /api/logout`. 5 wrong passwords per address → 60 s wait. Pages redirect to `/login`, APIs return 401 (the UI then goes to `/login`). HTTP Basic auth still works for scripts. `/api/health` stays open.
  - `/api/shutdown` returns 409, and the UI hides `.quit-row` when `config.server_mode` is true.
  - There is no random-port fallback.
  - `/api/upload` saves into `default_folder` (the recordings folder) with `name (2).ext` de-duplication, via a hidden `.<hex>.uploading` partial file. Local mode still uses `state/uploads/<hex>/`.
  - The setup wizard is skipped (`setup_completed=True`), since the folders come from the container.
  - `GET /api/library` lists top-level files in the recordings and exports folders (registered download URLs, size, modified time, kind, free space). `POST /api/library/delete {path}` deletes only files directly inside those two folders, and refuses while a job is running.
- `/api/health` is answered **before** the host, auth and token checks; the Docker healthcheck depends on it.
- Local mode (the default) keeps the original strict loopback `Host`/`Origin` checks.
- `setup_snapshot()` and `diagnostics()` include `server_mode`.

### UI (`web/`)
- `basename` and `dirname` in `app.js` handle both `/` and `\`, and `dirname` keeps `C:\` as a drive root.
- Wording stays platform-neutral: "this computer", "in this browser", "your machine". Never "this Mac". Upstream keeps reintroducing "on this Mac" in draft and autosave strings, so check every merge.
- The runtime line shows `macOS` only when `platform === 'Darwin'`.
- **Server mode UI** (`applyServerMode()` in `app.js`, run when `config.server_mode`): no typing of server paths.
  - `body.server-mode` class; the "04 Files" tab (`#files-tab`, `#files-page`) is shown.
  - The output-folder labels are hidden and filled with `default_output`.
  - The Highlights and Effects source fields are read-only, with "Server files" plus "Upload" buttons. Camera cards say "Server files".
  - Badges read SERVER and the Quit row is hidden. `uploadFile(file,i,n,statusEl)` takes an optional status element.
  - The Files tab (`loadLibrary`, `libraryRow`) offers Upload recordings, Download, Delete, and "Highlights →"/"Effects →" for exported videos.
  - Local mode must look and behave exactly as upstream (no Files tab, editable paths).
- **Web look:** one look only (the Glass theme was removed in 2.1.2 by request: "i dont need glass, i just need it to look good"). `web/studio.css` loads after `app.css`; the 2.1.2 polish block at its end (wider settings column, field spacing, flex stats grid, text-only tab hover, phone header grid) overrides earlier rules, so put layout fixes there rather than adding new theme files. Keep select option labels short enough for half-width columns.
- When upstream adds a new tab, page or output field, make it work in server mode too: uploads instead of paths, outputs to `default_output`, and results downloadable.

### Docker and deployment files (ours only)
- `Dockerfile`: `python:3.12-slim` plus Debian `ffmpeg` (which includes libx264), `pip install -r requirements.txt`, `COPY *.py ./` (every module, so new upstream files are included), `COPY web ./web`, a world-writable `/state`, `MULTICAM_*` defaults (`/media/recordings`, `/media/exports`, roots `/media`), and a healthcheck on `/api/health`. If upstream adds non-Python runtime files (for example a new data folder), add them to the Dockerfile.
- `.dockerignore`, and `docker-compose.yml`: literal values, no `.env`, no `${}`. It matches the owner's Arcane setup below (port 4067, `/opt/Docker/appdata/multicam-studio/...`) plus `build: .` as a fallback.
- `.github/workflows/docker.yml` builds `linux/amd64,linux/arm64` and pushes `ghcr.io/palermostest25/multicam-studio` (`latest` on `main`, semver on `v*` tags, sha). Only pushes to `main` and tags trigger it.
- `Start Multicam Studio.bat`: the Windows launcher (venv plus pip on first run, then `server.py --open`). It uses CRLF line endings and `goto` labels rather than parenthesised blocks.
- README sections "Run on Windows" and "Run in Docker (Arcane, Portainer, Compose)". Keep them when upstream edits the README.

### 2.0 smart engine (Python) — ours
- `music.py` (beats, bars, sections), `vision.py` (keyframe picture scores, auto-framing focus) and `planner.py` (smart planner, short-clip windows) are imported by `multicam_edit.py`. `--planner classic` keeps upstream's `make_plan`/`plan_once` working (upstream's tests call them).
- Tests patch `engine.output_size` to shrink renders, so sizes go through `output_size(frame_size(...))`. Keep it that way.
- `fit` framing = whole picture over a blurred fill (`fit_filter`), `pad` = black bars, `crop` with optional `auto` (vision focus). The boxblur radius must stay <= a quarter of the small background size.
- Rendering: shots render in parallel (`--jobs`), with `fps=` before crop/scale, VideoToolbox encode/decode only on macOS (`--encoder auto`). Progress lines: `Deliverable i/n weight= done= total=: title`, then `Rendering n/N:` (server.py parses both).
- Server: `Studio.start` overwrites `cache_dir` (state/cache) and, in server mode, `output_dir` = `export_subfolder(output_subfolder)` inside `default_output`; never trust a client path there. The library lists 3 levels deep and delete accepts nested files inside the two folders only.
- **Parity rule:** `music.py` ↔ `macos/Sources/MulticamCore/MusicAnalysis.swift`, `vision.py` ↔ `VisionAnalysis.swift`, `planner.py` ↔ `Planner.swift`, and sync (`multicam_edit.synchronise`) ↔ `Sync.swift`. Change both sides together. Python tests: `tests/test_smart.py`; Swift: `cd macos && swift test`. The Swift audio decoder resamples with AVAudioConverter (`primeMethod = .normal`); AVAssetReader's own resampler adds a rate-dependent delay that skews sync by 20–30 ms.

- `hardware.py` (stdlib only; server.py and the demo import it) detects a working hardware encoder with a real one-frame encode: VideoToolbox on macOS, NVENC + CUDA decode on Linux/Docker with an NVIDIA GPU. `multicam_edit.encoder_args` and `vision.hardware_decoding` use it. `setup_snapshot()`/`diagnostics()` include `hardware`.
- Social clips: `--clips` takes several lengths (`15,30,60`), and the server stores `clip_lengths`. A project with `clips: 0` has clips off even when `clip_lengths` is set (the Mac app saves it that way). Clips go to `<export>/Social media/[part_00N_<audio>/]<L>s/<name>_<L>s_<n>_HH-MM-SS.ext`, apart from the part folders that hold the full edits (`SOCIAL_FOLDER`/`--clips-dir` in multicam_edit, set per part by `audio_batch`; `Engine.socialFolder` in Swift). The owner imports the whole `Social media` folder into another app.
- **Social media alternatives** (`clip_alternatives`, default on; `--no-clip-alternatives`, `--alternatives-dir` + `--alternatives-part`, `ALTERNATIVE_SHAPES`; `Engine.alternativeShapes`/`alternativeSources(_:shape:)`/`alternativeFolders` in Swift): every clip that has a shot from a vertical recording (oriented width < height) is also rendered twice, both with black bars, in `Social media alternatives/Landscape (bars on vertical shots)/[part_00N_<audio>/]<L>s/` (16:9) and `Social media alternatives/Vertical (bars on wide shots)/[part…/]<L>s/` (9:16), same file names. Recordings shaped like the copy (zoom-1 crop keeps ≥55%) fill it; everything else is `pad`. It only adds files; the normal clips must stay unchanged. The normal clips' bars-or-blur choice is `clip_framing` (`bars` = pad).
- **No social clips here** (`clip_excludes`, per audio part like `drops`; `--clip-exclude START,END`; `AudioPart.clipExcludes`/`Project.clipExcludes`): clip windows touching an excluded range are skipped in `planner.window_scores` ↔ `Planner.windows`. Full edits are unaffected.
- Looks (`Look.Style` in Swift ↔ `effects.STYLES`/`styles` in effects.py): none, warm, cool, mono, vintage, vivid, noir, silver, sepia, super8 (grain + vignette), faded. Add new ones to both, plus the web radio list and `Look.Style.title`.
- **Engines:** `engine` 1 or 2 (`--engine`, `Project.engine`, default 2). Engine 1 is frozen exactly as shipped in 2.1.3 (the owner was happy with it): never change its output. Put every change to cutting/clip choice behind `engine >= 2`. Today the only difference is the clip ending: Engine 2 plays one beat past the bar line so the clip lands the next downbeat (`tail`, fade over 60% of it); Engine 1 stops at the bar line. Check Engine 1 against a 2.1.3 cut list after planner changes. `--clip-framing smart|fit|crop|same` (`clip_framing` in multicam_edit ↔ `Engine.clipFraming` in Swift): smart crops only when the zoom-1 crop keeps ≥55% of the picture, otherwise fit with blur.
- `docker-compose.nvidia.yml` is the GPU variant of the compose (deploy.resources GPU reservation, `NVIDIA_VISIBLE_DEVICES`, `NVIDIA_DRIVER_CAPABILITIES`; literal values, no `.env`). The Docker workflow fails if the image's FFmpeg lacks `h264_nvenc`/`hevc_nvenc`. `docker-compose.truenas.yml` is the TrueNAS SCALE "Install via YAML" variant (user 568:568, `/mnt/tank/apps/multicam-studio/...`, NVIDIA reservation).

### Native macOS app (`macos/`) — ours
- Swift package: `MulticamCore` (engine), `MulticamStudio` (SwiftUI app), `mcstudio` (CLI), tests. `macos/build-app.sh` makes the universal app + DMG (`SIGN_IDENTITY`, `ARCHS`, `SCRATCH`, `DIST` env vars). Build scratch should live on the internal disk.
- It reads/writes the same project JSON as the web UI (`Project` in `Models.swift` maps the snake_case keys; keep new web keys in step).
- This is the Mac release. `desktop.py` and `packaging/` (the 1.x PyInstaller app) stay as upstream has them, but README/releases point to the native app. GitHub releases: `v2.x.y` tags with `Multicam-Studio-<version>-macOS.dmg`.
- Local test builds signed with the owner's Apple Development identity keep the macOS "removable volume" permission between builds; ad-hoc builds ask again each time.
- `EditPlan` records `partPath`/`clipCount`, and the app only uses `AppState.activePlan` (a plan that `matches` the current analysis). Shot camera indices point into one specific analysis; pairing a plan with another excerpt crashed 2.0.0 (index out of range in PlanSummary).
- Appearance: `Glass.swift` holds the Liquid Glass helpers (`glassSurface`/`glassCapsule`/`glassButton`/`glassGroup`), all gated by `@AppStorage("liquidGlass")` (default on) with `#available(macOS 26)` fallbacks. Classic mode must stay exactly the 2.1.0 look, so new custom chrome goes through these helpers with a `classic:` style.
- Sidebar selection is one `String?`: `"audio:<path>"` for excerpts, a file path for recordings.
- **Auto-update** (`Updater.swift`): checks `releases/latest` of this repo every 6 h (Settings toggle, "Check for Updates…" in the app menu), downloads the `-macOS.dmg`, verifies the `-macOS.dmg.sha256` asset, requires the new app's signature to be valid with the **same team and bundle identifier** as the running app, stages it beside the current app and swaps it after quitting. An ad-hoc signed app (no team) accepts any valid signature with the same bundle id; a team-signed one only the same team. Keep both assets on every release. **Signing (2026-10-24):** the owner's Apple Development certificate was revoked by Apple (`spctl` says `CSSMERR_TP_CERT_REVOKED`; apps signed with it won't launch), so releases are ad-hoc signed (`./build-app.sh` without `SIGN_IDENTITY`) until the owner makes a new certificate in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates. Check `spctl -a -vv` on the built app before releasing.
- The owner's installed copy is `/Applications/Multicam Studio.app` (signed with the Apple Development identity). The 1.x app was renamed to `/Applications/Multicam Studio 1.x.app`.

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
python3 -m py_compile *.py
node -e "new Function(require('fs').readFileSync('web/app.js','utf8'))"
python3 -m venv /tmp/mc-venv && /tmp/mc-venv/bin/pip install -q -r requirements.txt
/tmp/mc-venv/bin/python -m unittest discover -s tests -v      # upstream's tests
```

- **Local-mode smoke test:** `python server.py --port <p> --state-dir <scratch>`. `/` returns 200 with `Host: 127.0.0.1:<p>` and 403 with `Host: evil.com`.
- **Server-mode smoke test:** `MULTICAM_PASSWORD=pw python server.py --host 0.0.0.0 --port <p> --state-dir <scratch>`. Check: `/api/health` 200 without auth, `/` 303 to `/login` and `/api/config` 401 without auth, 200 after `POST /api/login`, a bad `Origin` gets 403, `/api/shutdown` gets 409, and `/api/config` has `server_mode: true`.
- Docker: if the environment can build images, `docker build .` and run the container with the smoke tests above. In the Claude Code cloud sandbox, `deb.debian.org` and GitHub release downloads are blocked, so the FFmpeg layer can't be built or installed locally and FFmpeg-dependent tests are skipped. Rely on the GitHub Actions build for the full image, and say plainly which checks were skipped.
- Windows can't be tested in the sandbox. Review Windows-specific code paths by reading them.

## Environment gotchas (cloud sandbox)

- Never `pkill -f "<pattern>"` with a pattern that also appears in the running shell command; it kills your own shell (exit 144). Use a bracket trick such as `pkill -f "port 1877[0]"`, or kill by PID.
- Docker builds need `--network host` and proxy build args. Debian mirrors are still blocked; PyPI works.
- Commit messages end with the attribution lines the harness provides.

## The owner's Arcane deployment (reference; not a file in the repo)

Server address 192.168.1.10 (LAN). The owner wants the web page password-protected (`MULTICAM_PASSWORD` in the compose `environment:`, literal value) so nobody else uses the GPU; `MULTICAM_ALLOWED_HOSTS` stays too. Shared host: all paths must be named volumes or under `/opt/Docker/appdata/<app>`. Port 4067. The image comes from GHCR, so it must be public or Arcane needs a ghcr.io login.

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
      # Only requests addressed to this host are accepted.
      MULTICAM_ALLOWED_HOSTS: "192.168.1.10"
      # Sign-in password for the web page. Change it before deploying.
      MULTICAM_PASSWORD: "change-me"
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
5. Server-mode file workflow: uploads land in recordings, a Files tab for download/delete, no server paths in the UI. Removed `.env` usage, and the compose has no sign-in (restricted to 192.168.1.10).
6. 2.0 (2026-10-21): merged upstream 1.3.0; added the native Swift app, smart planner (beats, sections, picture scores), output formats/codecs, social clips, blurred fit, auto framing, export subfolders in server mode, faster rendering. Verified on the owner's real 3-camera 26-09-26 set (sync matches 1.x offsets exactly).

## App overview (unchanged from upstream)

- `server.py`: stdlib HTTP server plus a job runner. It serves `web/`, and starts `multicam_edit.py` (edit engine) and `effects.py` (clip, effects and batch highlight exports) as subprocesses.
- `multicam_edit.py`: syncs cameras to the WAV bounce (NumPy/SciPy correlation, drift), builds the seeded shot plan and renders with FFmpeg/libx264.
- `highlights.py`: energetic clip planner (NumPy/SciPy).
- `desktop.py` and `packaging/`: the 1.x macOS app bundle (PyInstaller, signing). macOS-only; leave it as upstream has it. The 2.0 Mac release is the native app in `macos/`.
- `docs/USER_GUIDE.md` and `CHANGELOG.md`: upstream-maintained.
- Run from source: `python server.py --open` (needs Python 3.10+, numpy, scipy, ffmpeg and ffprobe on PATH).
