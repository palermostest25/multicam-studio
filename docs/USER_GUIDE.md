# Multicam Studio

A local browser interface and standalone Python editor for DJ sets with any number of camera angles. Add recordings and parts to each camera, choose the main angle, frame every clip, and plan cuts against the audio waveform. The audio bounce is the final timeline and the only output audio. Every recording part is independently aligned to that bounce. The original two-camera command-line workflow still works.

## Install the macOS app

Use the release DMG matching your Mac: **arm64** for Apple silicon (M1 and later), or **x86_64** for Intel. The packaged application targets **macOS 14 or later**. Open the DMG, drag **Multicam Studio.app** into **Applications**, then open it. The browser interface opens automatically. Python, NumPy, SciPy, FFmpeg and FFprobe are bundled; users do not need Homebrew, Terminal, pip, or an internet connection to edit and render.

The supplied release is **Developer ID signed, without Apple notarization**. The app and DMG are signed; the ZIP contains the signed app. No release has been submitted to Apple for notarization. If macOS blocks a downloaded copy you trust, use that app's **Open Anyway** option in System Settings → Privacy & Security. See `packaging/RELEASE.md` for building and signing your own copy.

The setup wizard checks the rendering tools and lets you choose your recordings and export folders. You can make new folders in the picker. Open **Settings** to change defaults, check tools, download diagnostics, or quit. The app's Dock/menu also provides **Open Multicam Studio** and **Quit**. Finish or cancel a running job before quitting.

Reopening the app opens the existing workspace. If another application uses the preferred local port, Studio chooses a free one. Processing continues if you close the browser tab. No footage is uploaded to an online service.

## Settings, projects and recovery

The packaged app keeps preferences, job records, previews and local uploads in `~/Library/Application Support/Multicam Studio`. Its startup log is `~/Library/Logs/Multicam Studio/desktop.log`. Your chosen export folder contains the finished videos. Do not delete working files while processing.

**Save project** exports a portable JSON file containing paths and settings. It does not copy footage. **Load project** restores it. A local browser draft also remembers unsaved project and Effects settings, with an explicit Restore/Discard choice after refresh. Use Save project for transfers between computers, browsers or browser addresses. Reconnect external drives before restoring projects.

Browser media requests may be cancelled during seeking or closing a tab. Studio handles these disconnects quietly, including byte-range playback. A genuine rendering failure appears in Session activity and the job log. Settings → Help & diagnostics downloads runtime and job-status information without recordings, session tokens or project contents.

## Run the source version

The source version remains available for customization. It requires Python 3.10+ and FFmpeg/FFprobe. Install FFmpeg with Homebrew if needed (`brew install ffmpeg`), then run these commands from the source folder:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install numpy scipy
.venv/bin/python server.py --open
```

To choose source and working folders explicitly:

```bash
.venv/bin/python server.py --open --default-folder "$HOME/Movies" --state-dir "$HOME/Library/Application Support/Multicam Studio"
```

The source server defaults to port 8765 and only accepts local connections. `--port 8766` selects a preferred alternative. Source scripts keep their working area in `.multicam-studio` beside the server unless `--state-dir` is supplied. The legacy `.command` launcher is a source-development convenience; the packaged app is the installation intended for users.

## The first edit

1. Select the audio bounce, add your cameras, and add every recording part to its correct camera. You can use A/B or add more angles with their own names. Parts may overlap, have gaps, or start after the bounce; they are not assumed to be continuous.
2. Pick an output folder and a movie name. Give horizontal and vertical renders different movie names if you override the defaults.
3. Choose **Horizontal** (3840 × 2160) or **Vertical** (2160 × 3840), then choose any of your cameras as the main camera.
4. Set each clip to **Fit** or **Crop**, check its framing preview, and choose shot lengths. **Cut scale** changes all hold durations at once: `0.5` cuts faster, `2` holds roughly twice as long. A fixed seed makes the shot choices repeatable when all timing settings and inputs stay the same.
5. Generate a plan before the long render. Inspect framing previews, sync offsets, camera coverage, and the cut list. Use the waveform to select intervals and force particular cameras where you want intentional cuts; the remaining edit follows your seed and rhythm settings.
6. Render the movie with the same settings. Enable overwrite when replacing existing plans, previews, or movies.

The browser interface also provides:

- **Browse Mac** to select files directly from your Mac or connected drives without copying them. The file input/upload option is a fallback and copies media into the Studio working area, with upload progress shown.
- A separate part list for every camera, with add, remove, and reorder controls. File details show duration, resolution, and whether an audio track is available. Part order is organizational; independently detected timing determines coverage.
- A framing editor and previews for each camera part before running a complete sync and plan. **Fit** preserves the whole frame with padding; **Crop** fills the selected output shape using a fixed centre and zoom.
- Save/load project files to keep your selected paths, crops, rhythm, markers, and sync overrides together. The saved project points to your media; it does not package the recordings. Reconnect the same drives before reloading it.
- Progress, processing logs, cancellation, and reconnection to the active job after refreshing the page. Closing a browser tab leaves the local server running; use Quit in Settings or the app menu when finished.
- A waveform and camera timeline, manual camera intervals, every cut and its source position, sync offsets, camera-share statistics, finished-video playback, and links to generated files.
- **Highlights** to choose an exported movie and save selected moments, and **Effects** to preview or render fades, colour adjustments, styles, vignette, and optional bounce.

In a source installation, uploads and job records are kept under `.multicam-studio` beside the server by default. Browsing existing recordings avoids upload copies. To use a different working location, start `server.py` with `--state-dir '/path/to/Studio Working Files'`. Do not remove working files while a job is active.

Camera identities are fixed: changing the main camera changes editing roles, not crop geometry. With main camera B, B receives the long holds and breakdowns; the other cameras provide cutaways. Do not rename your recordings to switch those roles.

In the original A/B command-line workflow, horizontal mode keeps A's wide framing and crops B to a fixed landscape region; vertical mode keeps B's portrait framing and crops A to a fixed portrait region. In a camera project and the web interface, each clip has its own Fit/Crop setting. **Fit** scales the entire image into the output and adds padding when aspect ratios differ. **Crop** fills the output with a fixed region; zoom `1` is the largest region matching the output shape, and larger zoom values select a tighter region. Crop centre values range from `0` to `1`: lower X moves left, higher X moves right; lower Y moves up, higher Y moves down. A crop clamps to the frame edge when necessary. The main multicamera edit uses fixed framing and straight cuts, with no animated crops, transitions, or editorial speed ramps. Optional effects can be applied separately to a finished export.

The **main camera share** defaults to `0.70`. It is a target, as are the average cutting pace and shot durations. Coverage gaps, marked sections, and available angles can prevent an exact ratio. During a main-camera gap, another available camera is used. If no camera covers a time, the video is black while the bounce continues.

## Choose how it runs

| Option | Use |
|---|---|
| Packaged macOS app | Recommended for installation. Includes the rendering runtime; opens the local browser interface and setup wizard. |
| Python local server | Development and customization; install the listed dependencies yourself. |
| Legacy `.command` launcher | Starts the Python source server in Terminal; requires its source folder and dependencies. |
| Plain local HTML file | Cannot run this editor by itself because Python/FFmpeg and filesystem access require the local backend. |
| Hosted or remote server | Not included. Requires a separate rendering/storage/access-control design. The included server only accepts local connections. |

## Original two-camera command-line workflow

The engine can still run by itself, without the web interface. From the Studio folder:

```bash
.venv/bin/python multicam_edit.py \
  --audio '/path/to/recordings/audio_bounce.wav' \
  --cam-a '/path/to/recordings/cam_a.MOV' \
  --cam-b '/path/to/recordings/cam_b_part1.MOV' \
  --cam-b '/path/to/recordings/cam_b_part2.MOV' \
  --output-dir '/path/to/exports' \
  --main-camera B --mode vertical --cut-scale 0.75 --seed 42 \
  --plan-only
```

Use the actual filenames on your drive. Render with the same options, removing `--plan-only` and adding `--overwrite` after inspecting the plan.

When no explicit input paths are supplied, the standalone script discovers `audio_bounce.wav`, `cam_a.mp4` or `cam_a.mov`, and corresponding B files beside itself. Either camera may instead have numbered parts such as `cam_a_part1.MOV`, `cam_a_part2.mp4`. Filename case does not matter. Explicit `--cam-a` and `--cam-b` accept files with other names and can each be repeated. Clips in different folders may have the same filename. The web interface uses their full paths; for a command-line sync override, use the full path when a filename is ambiguous.

Default movies are `multicam_cut.mp4` and `multicam_cut_vertical.mp4`. Cut lists, sync reports, and previews are also written into the selected output folder. Reusing the same mode and folder replaces its companion files when overwrite is enabled, even when the movie has a custom name. Use a separate output folder to keep multiple complete versions.

## Camera projects: three angles, parts, and framing

Use a JSON manifest with `--project` when you have more cameras or want a different framing choice for each clip. Audio, output, rhythm, and quality remain ordinary command-line flags; `--project` supplies the cameras and manual camera intervals. Paths in this example are placeholders: replace them with your actual files and choose override times covered by the selected recording.

Example `project.json`:

```json
{
  "cameras": [
    {
      "id": "A",
      "label": "Front wide",
      "clips": [
        {
          "path": "/Volumes/External/DJ Set/front-part1.MOV",
          "framing": {"mode": "fit", "center": [0.5, 0.5], "zoom": 1}
        },
        {
          "path": "/Volumes/External/DJ Set/front-part2.MOV",
          "framing": {"mode": "fit", "center": [0.5, 0.5], "zoom": 1}
        }
      ]
    },
    {
      "id": "B",
      "label": "Side hands",
      "clips": [
        {
          "path": "/Volumes/External/DJ Set/side.MOV",
          "framing": {"mode": "crop", "center": [0.5, 0.72], "zoom": 1}
        }
      ]
    },
    {
      "id": "C",
      "label": "Crowd angle",
      "clips": [
        {
          "path": "/Volumes/External/DJ Set/crowd.mp4",
          "framing": {"mode": "crop", "center": [0.45, 0.5], "zoom": 1.15}
        }
      ]
    }
  ],
  "shot_overrides": [
    {"start": 60, "end": 68, "camera_id": "B"},
    {
      "start": 120,
      "end": 128,
      "camera_id": "C",
      "source_path": "/Volumes/External/DJ Set/crowd.mp4"
    }
  ]
}
```

Run a plan:

```bash
.venv/bin/python multicam_edit.py \
  --project '/Volumes/External/DJ Set/project.json' \
  --audio '/Volumes/External/DJ Set/audio_bounce.wav' \
  --output-dir '/Volumes/External/DJ Set/Exports' \
  --mode horizontal --main-camera B --seed 42 --plan-only
```

Camera IDs identify editing angles; labels are names for your own organization. IDs must start with a letter, contain only letters, numbers, `_` or `-`, and be at most 32 characters; `BLACK` is reserved. They are case-sensitive in a project. Each example clip has an absolute `path`; relative paths are also accepted and are resolved from the project JSON folder. The static framing settings are `mode` (`fit` or `crop`), `center` (`[x, y]`, each from `0` to `1`), and `zoom` (`1` to `8`, for cropping). Fit ignores centre and zoom and always preserves the complete source image. A clip keeps its framing throughout the multicamera edit. Switching output orientation changes the target shape, so inspect previews again. The separate optional bounce effect is the only motion added by this effects workflow.

### Waveform and manual camera intervals

Load the bounce waveform, select a start/end interval, and choose the camera you want there. These intervals become `shot_overrides` on the bounce timeline, in seconds. `camera_id` chooses an angle; optional `source_path` pins that interval to one particular part from that angle. Leave the part unspecified when the editor may choose an available part. The rest of the movie continues to use the random seed, main-camera preference, and hold ranges. Moving a waveform override does not move or resync the underlying media. Overrides cannot overlap, must fit within the bounce, and must contain at least one output frame. The selected angle or pinned part must cover the entire interval after sync; otherwise planning stops with an explanation instead of silently choosing a different camera. Times are rounded to the output frame grid.

Audio-energy suggestions highlight louder sections and possible clip candidates. They do not semantically identify musical drops, DJ hand movements, or the best visual moment. Listen, inspect the footage, and adjust suggested intervals before using them.

## All engine controls

Run `.venv/bin/python multicam_edit.py --help` for the exact installed option list. These command-line examples use the local `.venv` created by the manual setup commands above; the double-click launcher can instead reuse an existing recording environment automatically.

| Flag | Meaning / default |
|---|---|
| `--project PATH` | JSON camera manifest for any number of cameras, per-clip framing, and manual camera intervals; see the project example above. |
| `--cam-a PATH`, `--cam-b PATH` | Camera files; repeat for parts. Supports `.mp4` and `.mov`, including uppercase extensions. |
| `--audio PATH` | Audio bounce path. |
| `--output-dir PATH` | Destination for video and companion files; defaults beside the engine. |
| `--output-name NAME` | Custom movie filename; `.mp4` is optional. |
| `--report-json PATH` | Custom machine-readable report location. |
| `--mode horizontal\|vertical` | 3840 × 2160 or 2160 × 3840; default horizontal. |
| `--main-camera ID` | Which angle receives longer holds and breakdowns; default A in the original workflow, or the first camera in a project. |
| `--main-share 0.7` | Target share for the main camera. |
| `--seed 42` | Repeatable random shot choices. |
| `--cut-scale 1` | Multiplier for all hold durations and the target average cutting interval. |
| `--main-hold 20 60` | Main-angle hold range in seconds, before scaling. |
| `--cutaway-hold 4 12` | Secondary-angle hold range in seconds, before scaling. |
| `--drop-hold 3 6` | Alternating hold range during drops, before scaling. |
| `--breakdown-hold 15 30` | Breakdown hold range, before scaling. Adjacent shots on the same camera are joined, so a breakdown can remain uncut longer. |
| `--a-center 0.5 0.5` | Legacy A crop centre for vertical output. Projects use each clip’s framing settings instead. |
| `--b-center 0.5 0.72` | Legacy B crop centre for horizontal output. Projects use each clip’s framing settings instead. |
| `--fps 30` | Output frame rate: 24, 25, 30, 50, or 60. |
| `--drop START,END` | Repeat for drop/peak intervals on the bounce timeline. |
| `--breakdown START,END` | Repeat for breakdown intervals. |
| `--activity TIME` | Repeat for known hand movements or physical reactions to favour a cutaway. |
| `--no-auto-sections` | Disable approximate sections based on audio energy. |
| `--offset NAME=SECONDS` | NAME may be a unique filename or a full source path. Manual bounce time of a file's first video frame. Positive means that camera started late. Repeat per file. |
| `--drift-ppm NAME=VALUE` | Manual constant clock correction, within ±2000 ppm; NAME is a unique filename or full path. Requires an `--offset` for the same file. Repeat per file. |
| `--no-drift` | Use offset-only sync and reject significant detected drift. |
| `--crf 18` | H.264 quality, 0–51. Lower means higher quality and usually larger files. |
| `--preset medium` | Encoding speed: ultrafast, superfast, veryfast, faster, fast, medium, or slow. Faster presets usually need more space at the same quality target. |
| `--plan-only` | Sync and write plans/reports/previews without rendering a movie. |
| `--overwrite` | Allow existing outputs to be replaced. |

Marker times accept seconds or `HH:MM:SS` with optional fractions, for example `--drop 00:04:12,00:04:36 --activity 00:04:18.5`. Markers remain at the same bounce times when cut scale changes. Automatic energy sections are approximate suggestions, not recognition of musical drops or visible hand movements. Use manual markers for precise choices.

## Sync and rendering behaviour

The engine extracts mono audio at 8 kHz and compares waveform samples against the bounce using NumPy and SciPy. Several anchors must agree. Each part is checked independently. Reliable, consistent clock drift is corrected by timestamp calibration; it does not add creative speed effects.

The printed sync model is:

```text
bounce_time = offset + rate × camera_video_time
```

For example, offset `+12` and rate `1` means the first camera frame belongs at 12 seconds into the bounce. Bounce time 30 seconds uses camera time 18 seconds. Review the printed offsets and previews. Repeated musical phrases, very different audio mixes, loud crowd noise, silence, and reverberation can defeat waveform matching. Low-confidence matching stops with an explanation; use per-file manual offsets only when you have checked them.

The bounce must represent the same performance without rearrangements. Constant clock correction cannot fix arbitrary edits or timing jumps inside one camera file. Rendered segments are aligned to one output frame grid, concatenated with straight cuts, and muxed with the bounce as a single AAC audio track. Camera sound is discarded. The movie ends at the bounce duration to within one video frame.

4K encoding can take longer than the original set. Plan-only is much faster. A faster preset such as `veryfast` usually speeds up the render, at the cost of larger output. Processing uses CPU H.264 encoding. Allow space for the finished movie plus temporary segments, and keep the source and output drives connected. An existing final movie is replaced only after the new movie passes stream and duration checks.

## Source and release files

- `multicam_edit.py`: standalone editor, sync, shot planning and 4K rendering.
- `server.py`: local HTTP interface, preferences, job lifecycle and media streaming.
- `effects.py`: single and batch highlight export, plus effects rendering.
- `highlights.py`: energetic highlight planning across the full recording.
- `desktop.py`: packaged macOS application and render-worker entrypoint.
- `web/`: editor, waveform/crop tools and setup wizard.
- `packaging/`: repeatable native builds, dependency versions, licenses, signing and notarization procedure.
- `packaging/sign_release.py`: signed release packaging, component signature checks, and installation/runtime verification for both installer formats.

Release outputs include architecture-specific DMGs/ZIPs, checksums, a dependency audit and matching application/FFmpeg/x264 source archives. Keep third-party notices and source archives with redistributed binaries. See `packaging/RELEASE.md` for build details and the exact tested platform scope.

## Highlight clips and optional effects

In **Highlights**, choose a finished MOV or MP4 and enter an **Approximate clip length** between 2 and 300 seconds. Click **Find energetic clips** to scan the whole recording. Long energetic passages are divided into separate clips near your chosen length. Adjacent peaks can share a clip; suggestions do not overlap. There is no top-20 limit. Loudness is only a suggestion, so review the moments before exporting.

All suggestions are selected initially. Use **Review** to put a clip's range on the waveform, then **Play selection** to hear it. Tick individual clips or use **Select all / Select none**. Choose an output folder and filename prefix, then click **Export selected clips**. Each clip becomes a separate H.264 MP4 with a sequential number and source timestamp. A `<prefix>_highlights.json` manifest records the ranges and saved paths. Changing the source or target length requires finding clips again. You can export up to 1,000 clips per batch.

Batch export checks all output names before rendering. Existing files are preserved unless **Replace existing clips and batch manifest** is enabled. Progress and cancellation apply to the whole batch; completed clips are retained if a later clip fails or you cancel. Each completed clip has an **Open in Effects** button. Manual waveform selection and **Export selection** remain available for exact start/end times; reviewing or editing a manual selection does not change the batch's suggested ranges.

In **Effects**, choose a finished movie or highlight and select a colour style using the inline radio choices. These support mouse, touch, Tab and arrow keys without opening a macOS dropdown menu. Choosing a style does not start a render; click **Preview first 5 seconds** or **Export with effects** to apply it. You can process a selected interval or the whole movie. This creates a separate H.264 MP4 and preserves the source dimensions, frame rate, and audio channel count. There is no playback-speed change. Setting all effects to neutral makes a plain trimmed clip.


Available effects are video-and-audio fade-in/out, a small camera-bounce motion, warm/cool/monochrome/vintage/vivid styles, brightness, contrast, saturation, and vignette. Bounce enlarges the picture slightly and moves the crop inside it; at full strength movement is at most 3% of the original width/height in either direction, with no exposed black edges. It is an optional effect on the finished export, independent of the original fixed camera crops.

Fade lengths refer to the complete selection and together cannot exceed its duration. **Preview** renders the first five seconds at most, at the source resolution. A fade-out at the selection's end may be outside that preview. Preview filenames always gain `_preview`, including custom names, so previewing cannot replace the full export. The full render always applies fades at the selected beginning/end.

The effects engine also works from Terminal:

```bash
.venv/bin/python effects.py --config effects-settings.json --report-json effects-report.json
```

Example `effects-settings.json` (replace these paths with your movie and destination):

```json
{
  "source_path": "/path/to/exports/multicam_cut_vertical.mp4",
  "output_dir": "/path/to/exports/Highlights",
  "output_name": "drop-highlight",
  "start": 252,
  "end": 282,
  "overwrite": false,
  "preset": "veryfast",
  "crf": 18,
  "fade_in": 0.5,
  "fade_out": 1,
  "bounce": 0.2,
  "style": "warm",
  "brightness": 0,
  "contrast": 1,
  "saturation": 1,
  "vignette": false,
  "preview": false
}
```

Use `end: null` to continue through the source movie's end. Effect ranges: bounce `0–1`, brightness `-0.3–0.3`, contrast `0.5–2`, and saturation `0–2`. Style names are `none`, `warm`, `cool`, `mono`, `vintage`, and `vivid`. Fades and start/end times are seconds. The original movie is protected even when an output path is a symlink or hard link to it. Existing output files require overwrite, and a new movie is checked before it replaces an earlier export.
