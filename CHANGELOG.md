# Changes

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
