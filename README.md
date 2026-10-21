# Multicam Studio

Turn a DJ set into content. Give it the set's audio and every camera angle: it syncs the cameras to the audio, finds the tempo, bars, breakdowns and drops, cuts between angles on the beat, and exports a full edit for YouTube plus short vertical clips for Instagram Reels, YouTube Shorts and TikTok.

It comes in two forms:

- **A native macOS app** (Swift, SwiftUI and AVFoundation): small, fast and hardware-accelerated. Live preview of the edit before you export, GPU framing and colour, VideoToolbox encoding. No Python, FFmpeg or browser needed.
- **A web app** (Python and FFmpeg) for Docker, Linux, Windows and source installs. It has the same smart editing, formats and social clips in a browser, served from your machine or a home server.

Both read and write the same project files, so a project can move between them.

## What it does

- **Sync**: every camera recording (and every part of a camera) is matched to the set audio by waveform correlation, including camera clock drift. Cameras can start before or after the audio, end early, or have gaps.
- **Music-aware cutting**: beat tracking and bar lines on the set audio. Breakdowns are found where the kick and bass drop out, builds just before they return, and drops right after. Cuts land on bar lines and phrase starts; every drop gets a cut on its first downbeat. Shots are quick in drops, accelerate through builds and hold long in breakdowns.
- **Picture-aware camera choice**: each camera is scored over time for darkness, blur, being knocked or handled, someone standing in front of the lens, and on-screen activity. The edit leaves a camera before its picture goes bad and favours the busiest good angle when the music peaks. It avoids A-B-A-B ping-pong with three or more angles, and keeps your main camera near its screen-time target.
- **No flash frames, no black**: every shot has a minimum length. A camera that runs out hands over to one that still has footage. The picture is only black where no camera recorded at all, and short clips are only taken from stretches with footage.
- **No black bars**: *Crop* fills the frame (and can **follow the action automatically**, centring on where the movement is). *Fit* shows the whole picture over a soft blurred copy of itself. Plain black bars are still available as *Bars*.
- **Formats**: 16:9 (YouTube), 9:16 (Reels, Shorts, TikTok), 1:1 and 4:5 (Instagram feed), at 4K, 1440p, 1080p or 720p and 24–60 fps, as H.264, HEVC or ProRes 422.
- **Social clips**: on export, chop the set into clips at several lengths at once (for example 15, 30 and 60 seconds; each length gets its own folder beside the full edit). Clip lengths snap to whole bars, so 15 s at 128 BPM is exactly 8 bars. Pick the **best moments** (energy, plus a build-up into a drop placed early in the clip) or the **whole set in order**. Clips are rendered straight from the original footage with their own quicker editing, not cut out of the full edit. Cropping wide footage to 9:16 often cuts the DJ off, so clip framing defaults to **Smart**: wide shots are shown whole over a blurred background, and only near-matching shapes are cropped. *Crop*, *Fit* and *Same as the full edit* are also available.
- **Choose where it goes**: pick any output folder (in Docker, a folder inside Exports). Full edits and a `<name>_clips` folder land there, with a cut list.
- **Direct the edit**: force a camera over any stretch, mark drops and breakdowns yourself, set manual sync offsets, choose the main camera, pace and seed.
- **Several excerpts**: a set split into several audio files exports one video (and its clips) per excerpt, all against the same long camera recordings.
- **Looks**: warm, cool, mono, vintage and vivid styles, brightness/contrast/saturation, vignette and fades. The native app applies them while rendering; the web app has a separate Effects tab.

## Speed

On an M4 Mac mini, a real set with three iPhone cameras (two 4K HEVC 60 fps, one 1440p), all files on an external drive:

| | 60 s at 4K | 60 s at 1080p | 13 min 39 s set at 1080p + three 15 s Reels |
| --- | --- | --- | --- |
| 1.x (software FFmpeg, one shot at a time) | 879 s | – | – |
| 2.0 web app, hardware encoding | 113 s | – | – |
| 2.0 web app, software, `veryfast` | – | 45 s | – |
| **2.0 native app** | **30 s** | **13 s** | **3 min (4.7× real time); each Reel ≈ 2.5 s** |

Native sync, music analysis and picture scoring for those three cameras took 50 s the first time and about 1 s after that (results are cached).

## Install the Mac app

Download `Multicam-Studio-2.0.0-macOS.dmg` from the [latest release](https://github.com/palermostest25/multicam-studio/releases/latest). It runs on macOS 14 Sonoma or newer, on Apple silicon and Intel. Open the DMG and drag **Multicam Studio** into **Applications**.

The app is signed but not notarized by Apple. The first time, Control-click it and choose **Open**, or use **System Settings → Privacy & Security → Open Anyway**. When your recordings are on an external drive, macOS asks once for permission to read it: click **Allow**.

## Make an edit (Mac app)

1. Drag in the set audio and your camera files. Each video becomes its own camera; add more parts to a camera from the sidebar. Star your main camera.
2. Click **Sync & Analyse**. The sidebar shows how each camera lines up, and the timeline shows the waveform, breakdowns (blue), builds (yellow), drops (pink), clip windows and each camera's planned shots.
3. Press play: the preview is the real edit, rendered live from the original files. Change the pace, main camera share or seed (**Shuffle**) and it re-plans instantly. Drag across the timeline to force a camera or mark a section.
4. In **Framing**, choose Crop (with "Follow the action"), Fit or Bars for each recording and see the crop for each output shape.
5. In **Export**, choose the folder, the full edit's shape and size, the short clips (length, how many, best moments or whole set, shape), codec, quality and look. Then click **Export**.

**File ▸ Make Clips from a Finished Video…** cuts any finished video into beat-aligned clips (the 1.x Highlights tab).

Projects are JSON files (**File ▸ Save Project**). The app also keeps a draft of your current project automatically.

## Run the web app from source

Use Python 3.10 or newer and FFmpeg/FFprobe. From this repository's folder:

```sh
brew install ffmpeg
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python server.py --open
```

The editor engine is `multicam_edit.py`; run `.venv/bin/python multicam_edit.py --help` for its options, for example:

```sh
.venv/bin/python multicam_edit.py --project project.json --audio set.wav --output-dir exports \
  --aspect 16:9 --resolution 1080 --codec h264 --clips 15 --clip-count 5 --clip-aspect 9:16
```

On a Mac the web app uses VideoToolbox hardware encoding and decoding automatically (`--encoder auto`). Elsewhere it encodes in software, where 1080p with the `veryfast` preset is the quick choice.

## Try the interface without installing anything

`demo.py` runs the whole interface with only Python's standard library. There's no virtual environment, pip, NumPy, SciPy or FFmpeg. Double-click **Start Demo.bat** on Windows, or run `python demo.py --open` (`py demo.py --open` on Windows). It opens on port 8766 with a sample project: three placeholder camera files and a generated audio bounce.

Probing, framing previews, waveforms, highlight suggestions and preview plans all work, using drawn SVG frames instead of real video. Rendering, clip export and effects stop with a message instead of writing a file. Demo data lives in `.multicam-demo/`.

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

In Docker the studio runs in **server mode**: you never type server paths. Upload recordings and audio from your browser (camera cards, the Highlights and Effects **Upload** buttons, or the **Files** tab). They're saved in the recordings folder. Finished videos go to the exports folder, or to the **Folder inside Exports** you name in Output (for example `Reels/Friday`, created automatically). The **Files** tab lists both folders including subfolders, with **Download**, **Delete**, free disk space, and shortcuts that send an export to Highlights or Effects. **Server files** picks something already on the server. Project drafts stay in each viewer's browser. Settings → **Quit** is hidden in server mode; stop the container from Arcane instead. Anyone who can reach the port can use the studio, so set `MULTICAM_PASSWORD` and put it behind HTTPS (a reverse proxy) before exposing it beyond your home network.

### With an NVIDIA GPU (for example a T1000)

The image's FFmpeg includes NVENC and NVDEC. Install the NVIDIA driver and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) on the host (`sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`; `docker run --rm --gpus all ubuntu nvidia-smi` should list the card). Then deploy [`docker-compose.nvidia.yml`](docker-compose.nvidia.yml) instead of `docker-compose.yml`. It is the same file plus the GPU reservation and `NVIDIA_*` settings. Renders then use NVENC for H.264/HEVC and CUDA for decoding, and camera picture scoring runs by default. The Output section and Settings → Help & diagnostics show the encoder in use. Without a working GPU the studio falls back to software encoding. Run `python hardware.py` (or `docker exec multicam-studio python hardware.py`) to see what was detected.

Without a GPU, containers have no hardware video encoder, so camera picture scoring is off by default there (choose **On** under Editing rhythm to enable it; it decodes keyframes in software). 1080p with the `veryfast` preset renders much faster than 4K.

The same server mode works without Docker: `python server.py --host 0.0.0.0` (every option also has a `MULTICAM_…` environment variable; see `python server.py --help`).

## Build the Mac app

With Xcode 15 or newer:

```sh
cd macos
./build-app.sh                       # universal app + DMG in macos/dist (ad-hoc signed)
ARCHS=arm64 ./build-app.sh           # Apple silicon only, quicker
SIGN_IDENTITY="Developer ID Application: …" ./build-app.sh
swift test                           # engine tests (the end-to-end test needs FFmpeg to make sample footage)
```

`macos/Sources/MulticamCore` is the engine (sync, music and picture analysis, planner, GPU compositor, hardware export). `MulticamStudio` is the SwiftUI app, and `mcstudio` is a command-line front end: `mcstudio render project.json [--plan-only] [--range START,END]`, `mcstudio music set.wav`, `mcstudio vision camera.mov`. The 1.x PyInstaller bundle (`desktop.py`, `packaging/`) is still in the repository but is no longer the Mac release.

## Tests

```sh
.venv/bin/python -m unittest discover -s tests -v     # web engine, server, planner, music, formats, clips
cd macos && swift test                                 # native engine
```

## Third-party sources

The native app uses only Apple system frameworks. The web app and Docker image use Python, NumPy, SciPy and FFmpeg under their own licenses; see [third-party notices](packaging/notices/THIRD-PARTY-NOTICES.txt) for the 1.x bundled builds.
