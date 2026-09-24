# Multicam Studio

A local editor for multicamera DJ recordings, as a macOS app, from source on macOS, Windows or Linux, or as a Docker web service. Sync camera audio to a master bounce, generate a seeded edit, position fixed crops, direct important cuts on a waveform, and export highlights with optional effects.

## Install

[Download the latest release](https://github.com/ZeusyBoy99/multicam-studio/releases/latest). Requires **macOS 14 Sonoma or newer**.

| Your Mac | Installer |
| --- | --- |
| Apple silicon (M1 and later) | `Multicam-Studio-1.2.0-macOS-arm64.dmg` |
| Intel | `Multicam-Studio-1.2.0-macOS-x86_64.dmg` |

Open the DMG, drag **Multicam Studio** into **Applications**, and open it. The setup wizard helps you choose recordings and export folders. Python, NumPy, SciPy, FFmpeg and FFprobe are included. Editing works locally without internet or a Terminal window.

The apps and DMGs are **Developer ID signed, without Apple notarization**. If macOS blocks a trusted downloaded copy, use **System Settings → Privacy & Security → Open Anyway** for that app.

## Make an edit

1. Add the master audio bounce, then add cameras and their recording parts.
2. Choose landscape or portrait output, your main camera, and the cutting rhythm.
3. Set each clip to fit or crop; drag its crop in the preview to choose the fixed framing.
4. Use the audio waveform to place important camera changes. The remaining cuts follow your random seed.
5. Build a preview plan, then render. Use **Highlights** to select clips and **Effects** to style an export.

## Included tools

- Any number of cameras, with independently synchronized recording parts and MOV/MP4 support.
- Audio correlation, printed offsets, manual sync overrides and optional constant drift correction.
- Landscape 3840×2160 or portrait 2160×3840 H.264 output, with the master bounce as the only audio track.
- A selectable main camera, adjustable hold lengths, primary-camera share and random seed.
- Fixed framing for individual clips, with a draggable full-picture crop preview.
- Audio playback, waveform selection and manual camera/part intervals.
- Batch energetic highlights across the full recording, with adjustable approximate clip length, selection controls and separate MP4 exports.
- Manual clip export, fades, bounce and six directly selectable colour styles.
- Saved projects, draft recovery, progress, cancellation, render history and setup diagnostics.

Energy suggestions use audio analysis; they do not recognize the DJ's hand movements or guarantee musical drop detection. Camera motion is not added to the main edit; bounce is an optional effect applied afterward.

See the [complete user and command-line guide](docs/USER_GUIDE.md) for controls, examples and syncing details.

## Run from source

Use Python 3.10 or newer and FFmpeg/FFprobe. From this repository's folder:

```sh
brew install ffmpeg
python3 -m venv .venv
.venv/bin/python -m pip install numpy scipy
.venv/bin/python server.py --open
```

The standalone editor is `multicam_edit.py`; run `.venv/bin/python multicam_edit.py --help` for its options. The browser interface runs on a local server. A plain HTML file cannot render video by itself.

## Run on Windows

Install Python 3.10 or newer and FFmpeg (which includes FFprobe), for example:

```bat
winget install Python.Python.3.12
winget install Gyan.FFmpeg
```

Then double-click **Start Multicam Studio.bat**. The first run creates a `.venv` folder and installs NumPy and SciPy; later runs open the studio in your browser directly. Keep the window open while editing or rendering, and press Ctrl+C in it to stop. The file browser lists your home folder and each drive letter.

To start it by hand instead:

```bat
py -3 -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
.venv\Scripts\python server.py --open
```

## Run in Docker (Arcane, Portainer, Compose)

The Docker image serves the same web interface to other machines, so you can run it on a home server or NAS and open it from any browser. Renders run inside the container with its own FFmpeg.

1. Create the folders on the host and give them to the user the studio runs as (uid/gid 1000 by default):

   ```sh
   sudo mkdir -p /opt/Docker/appdata/multicam-studio/{recordings,exports,state}
   sudo chown -R 1000:1000 /opt/Docker/appdata/multicam-studio
   ```

2. In Arcane, create a new project (stack) from [`docker-compose.yml`](docker-compose.yml). All settings are written directly in that file, with no `.env` file. Edit them there:

   | Setting | Purpose |
   | --- | --- |
   | `user` | uid:gid the studio runs as; owner of exported files |
   | `ports` | `4067:8765` publishes the studio on host port 4067 |
   | `MULTICAM_PASSWORD` | Optional browser sign-in (any user name). Leave it out on a trusted home network |
   | `MULTICAM_ALLOWED_HOSTS` | Host names or IPs you open the studio with, comma-separated (for example the server's LAN IP). Keep it set when there's no password |
   | `volumes` | Recordings (`/media/recordings`), exports (`/media/exports`) and app state (`/state`) |

3. Deploy, then open `http://<server>:4067`.

The compose file uses `ghcr.io/palermostest25/multicam-studio:latest`, which the included GitHub Actions workflow builds for amd64 and arm64 on every push to `main`. The package is private until you make it public in the repository's **Packages** settings (or log Arcane in to `ghcr.io`). If the image cannot be pulled, Compose builds it from this repository instead. To run it without Compose:

```sh
docker build -t multicam-studio .
docker run -d --name multicam-studio --init -p 4067:8765 --user 1000:1000 \
  -e MULTICAM_PASSWORD=change-me \
  -v /opt/Docker/appdata/multicam-studio/recordings:/media/recordings \
  -v /opt/Docker/appdata/multicam-studio/exports:/media/exports \
  -v /opt/Docker/appdata/multicam-studio/state:/state multicam-studio
```

In Docker the studio runs in **server mode**: you never type server paths. Upload recordings and bounces from your browser (camera cards, the Highlights and Effects **Upload** buttons, or the **Files** tab). They're saved in the recordings folder, and finished videos go to the exports folder automatically. The **Files** tab lists both, with **Download**, **Delete**, free disk space, and shortcuts that send an export to Highlights or Effects. **Server files** picks something already on the server. Project drafts stay in each viewer's browser. Settings → **Quit** is hidden in server mode; stop the container from Arcane instead. Anyone who can reach the port can use the studio, so set `MULTICAM_PASSWORD` and put it behind HTTPS (a reverse proxy) before exposing it beyond your home network.

The same server mode works without Docker: `python server.py --host 0.0.0.0` (every option also has a `MULTICAM_…` environment variable; see `python server.py --help`).

## Build the macOS apps

See [release building and signing](packaging/RELEASE.md) and [Developer ID certificate setup](packaging/SIGNING-SETUP.md). Builds are separate for Apple silicon and Intel. The signing helper never submits to Apple for notarization.

Release checks cover runtime-component signatures, real DMG/ZIP installation copies and bundled rendering. Intel builds are checked under Rosetta. Physical Intel hardware and a separate macOS 14 machine were not available for testing.

## Tests

With the source dependencies and FFmpeg on your PATH:

```sh
.venv/bin/python -m unittest discover -s tests -v
```

The tests exercise whole-recording highlight detection, approximate durations, all colour styles, real clip rendering, collision protection and retaining completed clips after cancellation.

## Third-party sources

Bundled components retain their own licenses; see [third-party notices](packaging/notices/THIRD-PARTY-NOTICES.txt). Each release includes matching Sources archives with the application, exact FFmpeg/x264 sources and build recipes. Keep the matching Sources archive with the binary package when redistributing it.
