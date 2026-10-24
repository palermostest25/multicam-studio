# Changes

## 2.8.1

- AI mode: the Claude Code and Codex tools no longer pick up settings from a Claude Code session the app happened to be started from. When the claude tool's own sign-in has expired (it is separate from the Claude app), the message now says to run `claude auth login`.
- AI mode: an error message clears when you switch provider or change the model.

## 2.8.0

- **AI mode** (optional; off by default, so nothing changes unless you turn it on). Turn it on with the **AI mode** button (browser header; Mac toolbar, View ▸ AI Mode or Settings) and an AI panel appears. Describe what you want (“more of camera C in the drops, no clips from the first two minutes, black and white breakdowns”) and choose who answers:
  - **Claude Code** or **Codex**, using the app signed in with your subscription on the studio machine (or this Mac), or
  - **OpenRouter** with an API key (saved on the studio, or in the Mac's Keychain; Docker can also take `MULTICAM_OPENROUTER_KEY`).
  The AI only fills in the settings you could set by hand (main camera, screen time, pace, forced cameras, drops and breakdowns, no-clip ranges, clip lengths, count and filters), so the engine makes every cut in the same style. Nothing changes until you apply, and **Undo** restores your settings.

## 2.7.0

- **Filters for social clips**, automatic by default: *Auto mix* makes about a third of the clips black and white (Noir or Silver, the calmer moments) and gives the rest varied colour looks (Original, Vivid, Vintage, Warm, Super 8, Faded film). You can also turn filters off or give every clip one look. The full edit is unaffected; the alternatives use the same look as their clip.
- **Tidy exports and nicer names.** One export folder for everything:
  - `Full sets/26-09-26-1.mp4`
  - `Social media/26-09-26-1/15s/26-09-26-1 - 15s - 01 - 3m39s.mp4`
  - `Social media alternatives/<shape>/26-09-26-1/15s/…`
  - `Project files/26-09-26-1/` (cut list, report, previews)
  Sets are named after the audio file, or after the set name you type (“Friday - Part 1”, “Friday - Part 2”…).

## 2.6.1

- Mac app: the Look colour choice is a menu again; with the new looks the row of buttons was wider than the panel and pushed the whole Export tab over the preview.

## 2.6.0

- **No social clips here**: drag across the timeline (Mac) or select in the waveform (browser) and choose “No social clips here”, and social clips will never be taken from that stretch. Each audio excerpt keeps its own list (Mac: Export tab; browser: Social clips panel). The full edit is unaffected.

## 2.5.0

- Mac app **updates itself**: it checks for a new release every few hours (or Multicam Studio ▸ Check for Updates…), then downloads, verifies and installs it and relaunches. Turn automatic checks off in Settings.
- New looks in both apps: **Noir** and **Silver** (black and white), **Sepia**, **Super 8** (warm, grainy, vignetted) and **Faded film**; Monochrome is now called Black & white.
- Social clips framing has a **Black bars** option next to the blurred fit.
- **Social media alternatives** are now two black-bar copies of every clip that uses a vertical camera: `Landscape (bars on vertical shots)` in 16:9 and `Vertical (bars on wide shots)` in 9:16.

## 2.4.0

- Web app (Docker, TrueNAS): a proper **sign-in page** when `MULTICAM_PASSWORD` is set, instead of the browser's password pop-up. You stay signed in for 30 days (also across container restarts), there is a **Sign out** button, changing the password signs everyone out, and five wrong passwords make that address wait a minute. The compose files now set `MULTICAM_PASSWORD` (change `change-me`).
- Renders run on the server and keep going when you close the page or turn your computer off; reopen the page to see progress.

## 2.3.0

- **Social media alternatives** (on by default; Social clips settings in the Mac app and the browser). Every clip that uses a vertical recording is also saved in 9:16 in a `Social media alternatives` folder beside `Social media`, with the same subfolders and file names. The vertical camera fills the frame at its own shape and the wide cameras are shown whole with black bars, ready to upload to Instagram. Nothing else changes: the normal clips and full edits are exactly as before.

## 2.2.0

- **Engine 1 / Engine 2** (Mac app: Edit tab; browser: Editing rhythm). Engine 1 is frozen exactly as in 2.1.3. Engine 2 (the default) is where improvements go:
  - Social clips land on the beat: after the whole bars, a clip plays through the next downbeat and lets it ring for one beat with a short fade, so it finishes on the "one" instead of stopping a split second before it. Lengths are a guide (a "15 s" clip is about 15½ s at 128 BPM). Engine 1 still stops at the bar line.
- Social clips all go in one **Social media** folder at the root of the export, separate from the full edits: `Social media/part_001_<audio>/15s/…` when there are several audio excerpts, `Social media/15s/…` with one.

## 2.1.3

- Mac app: the preview keeps the exact shape of the edit (or the short clip you are previewing), so there are no black bands above and below the picture; the playback controls sit above it instead of over it.
- Mac app: the sidebar calls the black-bars framing "Bars", like the Framing tab, and the Framing tab warns when Fit or Bars would leave most of the frame empty (for example a vertical phone recording in a 16:9 edit).

## 2.1.2

- Mac app: changing a camera's framing (or look) updates the preview straight away, without re-planning the edit.
- Mac app: a restored project with all its files present is analysed on launch.
- Web app: the Glass look and its header switch are gone; there is one clean look. The settings column is wider so option names fit, fields line up in pairs, the edit overview stats wrap without leaving one on its own row, the selected tab is the only highlighted one, and on phones the header buttons sit in one tidy row.

## 2.1.1

- Mac app: **Liquid Glass** look (macOS 26+): the preview controls float over the video in glass capsules, with a glass status bar, timeline selection bar, buttons and clip-length chips. **Settings → Appearance** (or **View → Liquid Glass**, ⌥⌘G) switches back to the Classic look at any time; macOS 14–15 get the nearest material look.
- Web app (Docker, Windows, Linux, source): a matching **Glass** look (frosted panels, capsule buttons, tinted primary action) with a **Glass / Classic** switch in the header, remembered per browser.
- The sidebar has one selection: clicking an audio excerpt highlights it (and nothing else) and loads it; clip-length chips that are on are filled in both looks.

## 2.1.0

- Fixed a crash when switching between audio excerpts while the preview plays (2.0.0 could pair one excerpt's plan with another's cameras).
- Social clips export at several lengths in one go (default 15, 30 and 60 s), each in its own folder beside the full edit.
- Clip framing option: **Smart** (default; shows wide shots whole over a blurred background in vertical clips and crops only near-matching shapes), Fit, Crop, or Same as the full edit. Clips keep their quick, on-the-beat cuts.
- Fixed "Cannot start reading … error -11841" when exporting some clips: audio is now cut on exact video frame boundaries, and the video instructions always cover the whole composition.
- Recording clocks: each camera's recording start time is used to tell "not recording during this audio" (shown in grey) from a failed sync, to retry a failed sync around the expected overlap, and to suggest an offset when audio sync still fails.
- NVIDIA GPU support for the web app and Docker image: NVENC encoding and CUDA decoding are detected and used automatically (`hardware.py`). New `docker-compose.nvidia.yml`.

## 2.0.0

- **Native macOS app** in Swift/SwiftUI with an AVFoundation engine: live preview of the edit straight from the original files, GPU framing and colour, VideoToolbox hardware encoding. A 4.4 MB app with no Python, FFmpeg or browser. About 2× real time at 4K and 4.7× at 1080p, versus about 0.07× for 1.x at 4K.
- **Smart editing** (both versions): beat and bar tracking, and breakdown/build/drop detection from kick and bass. Cuts land on bar lines and phrases, and every drop is cut on its first downbeat. Shot lengths follow the section.
- **Picture-aware angles**: cameras are scored for darkness, blur, being handled or blocked, and on-screen activity. The edit leaves a camera before its picture goes bad and favours busy angles in drops. No flash frames: every shot has a minimum length.
- **Output formats**: 16:9, 9:16, 1:1 and 4:5 at 4K/1440p/1080p/720p; H.264, HEVC or ProRes; hardware encoding when available. Shots now render in parallel in the web engine, with frame-rate conversion before scaling.
- **Social clips**: export short clips (7–90 s, snapped to whole bars), either the best moments (favouring a build-up into a drop) or the whole set in order. Each clip has its own shape, size and quicker editing and is rendered from the source footage. Clips only use stretches with footage, so there is no black.
- **No black bars**: Fit now shows the whole picture over a blurred copy of itself (Bars keeps the old look). Crops can follow the action automatically.
- **Output folder**: choose any folder; in Docker, name a folder inside Exports. The Files tab lists subfolders.
- Set audio can be WAV, AIFF, FLAC, MP3 or M4A. The waveform shows breakdowns, builds and drops, and plan results list the planned clips.
- Merged upstream 1.3.0 (independent audio excerpt exports).

## 1.3.0

- Import multiple WAV excerpts against shared long camera recordings and export each as a separate video, including excerpts with gaps.
- Search the shorter audio recording inside the longer recording so excerpts late in a long camera file can sync reliably.
- Keep waveform markers, forced shots and manual offsets separate for each audio excerpt; preserve them in projects and drafts.
- Show per-excerpt plans, sync results, exports and warnings, and retain completed outputs if another excerpt fails or the batch is cancelled.
- Automatically use available cameras when an angle ends, and report cameras that cannot be confidently synced to a particular excerpt.

## 1.2.0

- Replace the Colour style popup with inline, keyboard-accessible style choices to avoid the reported macOS dropdown freeze.
- Find energetic highlights across the full recording, without the previous 20-suggestion cap. Split long energetic passages into clips with a chosen approximate length.
- Review, select and export highlights in a single batch, with separate timestamped MP4s and a range manifest.
- Report batch progress, retain completed clips on cancellation or failure, and send any completed clip to Effects.
- Check all batch destinations before rendering, including existing-file and source-file protection.

## 1.1.0

- Initial public release: multicamera editing, audio synchronization, waveform overrides, individual crop positioning, highlights, effects and signed macOS installers.
