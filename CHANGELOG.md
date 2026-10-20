# Changes

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
