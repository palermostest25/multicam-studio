#!/usr/bin/env python3
"""Static multicamera DJ edit for macOS. Python 3.10+; ffmpeg/ffprobe required.

Put this script beside audio_bounce.wav and cam_a.mp4 / cam_b.mp4, or select
files anywhere with --audio, --cam-a and --cam-b. Both cameras support numbered
parts such as cam_a_part1.MOV or cam_b_part2.mp4; repeat explicit path flags for
multiple parts. Every part is synced independently, including gaps and overlaps.
Camera files may use .mp4 or .mov, in any letter case, including .MOV. Mixing
formats between cameras/parts is fine; do not provide two versions of one part.

    brew install ffmpeg
    python3 -m venv .venv
    .venv/bin/python -m pip install numpy scipy
    .venv/bin/python multicam_edit.py --seed 42

Useful options:
    --project project.json          Any number of cameras, independent per-clip
                                    fit/crop framing and exact shot overrides
    --main-camera B                 Camera ID for the home angle; framing stays unchanged
    --cam-a /path/a.MOV             Repeat --cam-a / --cam-b for multiple parts
    --cam-b /path/b_part1.MOV --cam-b /path/b_part2.mp4
    --audio /path/bounce.wav        Explicit audio bounce
    --output-dir /path/exports      All outputs and temporary render segments
    --output-name My_Edit           Optional movie filename (without folders)
    --report-json /path/report.json Machine-readable sync / shots / output report
    --main-hold 20 60               Normal main-angle hold range, seconds
    --cutaway-hold 4 12             Normal secondary-angle hold range, seconds
    --drop-hold 3 6                 Alternating holds during a drop, seconds
    --breakdown-hold 15 30          Main-camera holds during breakdowns
    --main-share 0.7                Soft main-angle screen-time target (0 to 1)
    --mode horizontal               3840x2160: full A, landscape crop of B
    --mode vertical                 2160x3840: full B, portrait crop of A
    --a-center 0.5 0.5              Vertical mode: fixed A crop centre (x,y)
    --cut-scale 1                   Shot duration multiplier: 0.5 faster, 2 slower
    --plan-only                      Sync, crop previews and cut list; no movie
    --drop 60,90 --breakdown 120,150   Bounce-relative seconds or HH:MM:SS
    --activity 35 --activity 105      Known hand movements / physical reactions
    --no-auto-sections               Disable approximate audio-energy sections
    --b-center 0.5 0.72              Horizontal mode: fixed B crop centre (x,y)
    --offset cam_b_part1.mp4=12.345   Manual bounce time of first VIDEO frame
    --drift-ppm cam_b_part1.mp4=40    Manual constant clock-rate correction
    --no-drift                       Offset-only sync (reject measured drift)
    --overwrite                     Replace existing output files

With no drop/breakdown markers, smoothed audio energy suggests sections. This
does NOT recognise actual musical drops, hands, faces or mixer controls. Supply
markers for intentional cuts and inspect the fixed Camera B crop preview.
20-60s main / 4-12s cutaway holds cannot always meet 70/30 and 10-15s/cut;
these are soft targets. Coverage and marked sections take priority. No image motion is added.

Sync model: bounce_time = offset + rate * camera_video_time. A positive offset
means a late camera start. Each part is matched independently using several
normalised 8kHz waveform cross-correlations, not filenames or presumed continuity.
Consistent multi-anchor matches optionally correct small constant clock drift;
this is timestamp calibration, not an editorial speed ramp. No camera audio is
ever included in the output. Both-camera gaps become black while audio continues.

Horizontal mode (default) writes multicam_cut.mp4, cut_list.txt and
report_horizontal.json. Vertical mode writes multicam_cut_vertical.mp4,
cut_list_vertical.txt and report_vertical.json. Both modes include crop previews
for every source. Use --output-dir to choose their folder.
Use the same seed, cut scale and timing options in both modes for identical cuts.
Vertical mode preserves B's full portrait frame, not the landscape crop selected
by --b-center. Adjust --a-center X Y to move A's portrait crop; smaller X moves
left, larger X moves right. Neither crop is animated.

--cut-scale multiplies all normal, drop and breakdown hold ranges and the soft
10-15 seconds/cut target. For example 0.5 gives main 10-30s / cutaway 2-6s / drops 1.5-3s;
2 gives main 40-120s / cutaway 8-24s / drops 6-12s. The share target is unchanged.
For arbitrary cameras, --project reads {"cameras":[{"id":"Crowd","label":"Crowd",
"clips":[{"path":"crowd.MOV","framing":{"mode":"crop","center":[0.5,0.5],
"zoom":1}}]}],"shot_overrides":[{"start":10,"end":15,"camera_id":"Crowd"}]}.
Project paths may be absolute or relative to the project JSON. Each clip can fit
its full picture with padding, or use a fixed crop with zoom 1-8. Shot overrides
replace exact timeline ranges on the output frame grid; optional source_path
selects an exact part. Missing coverage is an error for requested overrides.
Sync overrides accept either a unique filename or /full/path/clip.MOV=SECONDS.
Use full paths when different camera folders contain identical filenames.

Section and activity markers remain at their original bounce times. Coverage and
section boundaries can shorten holds. Consecutive identical angles are merged,
so a breakdown stays on the main camera even if it exceeds the chosen hold range.
--activity marks moments for the SECONDARY angle, whichever camera is main.

H.264 3840x2160 or 2160x3840, fixed frame rate, bounce audio only. A video end is
quantised to a frame; -t limits the mux to the bounce duration (within one frame).
Temporary shot encodes need roughly another output file's worth of disk space.
References: https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.correlate.html
            https://ffmpeg.org/ffmpeg-filters.html
            https://ffmpeg.org/ffmpeg-formats.html#concat-1
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import itertools
import hashlib
import json
import math
from pathlib import Path
import random
import re
import shutil
import signal as os_signal
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

try:
    import numpy as np
    from scipy import signal, ndimage
except ImportError:
    sys.exit("Install dependencies: python3 -m pip install numpy scipy")

SR = 8000
WIDTH, HEIGHT = 3840, 2160
DEFAULT_SEED = 42
MIN_CORRELATION = 0.08
MAX_DRIFT_PPM = 2000
SYNC_TOLERANCE = 0.080  # seconds; refuse inconsistent anchor matches


def run(cmd):
    result = subprocess.run([str(x) for x in cmd], capture_output=True, text=True,
                            encoding="utf-8", errors="replace")
    if result.returncode:
        raise RuntimeError(f"{cmd[0]} failed:\n{result.stderr[-6000:]}")
    return result.stdout


def probe(path):
    return json.loads(run(["ffprobe", "-v", "error", "-show_streams",
                           "-show_format", "-of", "json", path]))


def number(obj, key, default=0.0):
    value = obj.get(key)
    return float(value) if value not in (None, "N/A") else default


def stream_duration(info, stream):
    if stream.get("duration_ts") is not None and stream.get("time_base"):
        a, b = map(int, stream["time_base"].split("/"))
        return int(stream["duration_ts"]) * a / b
    return number(stream, "duration", number(info["format"], "duration"))


def extract_audio(path, destination):
    # Reset the initial audio PTS but retain internal gaps. Analysis files are
    # raw float32 on disk, memory-mapped to avoid holding whole sets in RAM.
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
         "-i", path, "-map", "0:a:0", "-vn", "-ac", "1", "-af",
         "asetpts=PTS-STARTPTS,aresample=8000:async=1:first_pts=0,"
         "highpass=f=120,lowpass=f=3000", "-ar", SR,
         "-c:a", "pcm_f32le", "-f", "f32le", destination])
    if destination.stat().st_size < SR * 4:
        raise RuntimeError(f"Less than one second of usable audio: {path.name}")
    return np.memmap(destination, dtype="<f4", mode="r")


def match_anchor(reference, template):
    """Return best reference start and normalised correlation, bounded RAM.

    Each valid lag compares a complete template. Chunk overlap covers every
    reference position exactly once; unlike raw correlation this does not prefer
    loud sections. Absolute correlation also handles reversed microphone polarity.
    """
    template = np.asarray(template, dtype=np.float32).copy()
    template -= template.mean()
    m = len(template)
    energy = float(np.dot(template, template))
    if energy < 1e-9 or len(reference) < m:
        return 0.0, 0.0
    best = (0.0, 0.0)
    block = 120 * SR
    for start in range(0, len(reference) - m + 1, block):
        x = np.asarray(reference[start:start + block + m - 1], dtype=np.float32)
        numerator = signal.correlate(x, template, mode="valid", method="fft")
        cumulative = np.concatenate(([0.0], np.cumsum(x, dtype=np.float64)))
        squared = np.concatenate(([0.0], np.cumsum(x.astype(np.float64)**2)))
        sums = cumulative[m:] - cumulative[:-m]
        variance = np.maximum(squared[m:] - squared[:-m] - sums*sums/m, 0)
        scores = np.abs(numerator) / np.sqrt(np.maximum(variance * energy, 1e-20))
        scores[variance < 1e-9] = 0
        k = int(np.argmax(scores))
        if scores[k] > best[1]:
            best = ((start + k) / SR, float(scores[k]))
    return best


def fit_sync(matches, allow_drift):
    """Robust consensus prevents one repeated phrase overriding other anchors."""
    good = [(x, y, c) for x, y, c in matches if c >= MIN_CORRELATION]
    if len(good) < 2:
        raise RuntimeError("Too few reliable audio matches. Use --offset NAME=SECONDS "
                           "after manually checking sync; camera audio may be silent or unrelated.")
    x, y, confidence = np.array(good).T
    models = [(float(np.median(y-x)), 1.0)]
    if allow_drift and len(good) >= 3:
        for i, j in itertools.combinations(range(len(good)), 2):
            if abs(x[j] - x[i]) < 2:
                continue
            rate = (y[j] - y[i]) / (x[j] - x[i])
            if abs(rate - 1) <= MAX_DRIFT_PPM / 1e6:
                models.append((y[i] - rate*x[i], rate))
    ranked = []
    for offset, rate in models:
        residual = np.abs(y - (offset + rate*x))
        mask = residual <= SYNC_TOLERANCE
        ranked.append((int(mask.sum()), float(confidence[mask].sum()), mask))
    _, _, mask = max(ranked, key=lambda item: item[:2])
    if mask.sum() < max(2, math.ceil(len(good)*0.6)):
        raise RuntimeError("Audio matches disagree (repeated music, drift, or an edited "
                           "recording). Check sync and provide --offset / --drift-ppm.")
    if allow_drift and mask.sum() >= 3 and np.ptp(x[mask]) >= 5:
        rate, offset = np.polyfit(x[mask], y[mask], 1)
    else:
        rate, offset = 1.0, float(np.median((y-x)[mask]))
    if abs(rate-1)*1e6 > MAX_DRIFT_PPM or np.max(np.abs(y[mask]-offset-rate*x[mask])) > SYNC_TOLERANCE:
        raise RuntimeError("Sync has inconsistent clock drift; supply checked manual offsets.")
    # Do not silently extrapolate one small overlapping cluster across a long file.
    matched_span = float(np.ptp(x[mask]))
    if matched_span < 0.4 * float(np.ptp(np.array(matches)[:, 0])):
        print("  WARNING: matches cover a limited portion; verify sync at the far end.")
    return float(offset), float(rate), int(mask.sum())


@dataclass
class Camera:
    path: Path
    angle: str
    duration: float
    video_start: float
    format_start: float
    audio_start: float
    has_audio: bool
    offset: float = 0.0
    rate: float = 1.0
    first: int = 0
    last: int = 0
    sync_method: str = "automatic"
    matched_anchors: int | None = None
    label: str = ""
    framing: dict | None = None


def read_camera(path, angle):
    info = probe(path)
    videos = [s for s in info["streams"] if s["codec_type"] == "video"]
    audios = [s for s in info["streams"] if s["codec_type"] == "audio"]
    if not videos:
        raise RuntimeError(f"No video in {path.name}")
    v = videos[0]
    duration = stream_duration(info, v)
    if not math.isfinite(duration) or duration <= 0:
        raise RuntimeError(f"Cannot determine video duration: {path.name}")
    return Camera(path, angle, duration, number(v, "start_time"),
                  number(info["format"], "start_time"),
                  number(audios[0], "start_time") if audios else 0.0, bool(audios))


def discover_inputs(folder, audio=None, cam_a=None, cam_b=None):
    """Explicit paths override case-insensitive discovery for each input group."""
    files = [p for p in folder.iterdir() if p.is_file()]

    def one(stem, extensions, required=True):
        matches = [p for p in files if p.stem.lower() == stem and p.suffix.lower() in extensions]
        if len(matches) > 1:
            raise ValueError(f"Multiple versions of {stem}: " + ", ".join(p.name for p in matches)
                             + ". Keep only the intended input.")
        if not matches and required:
            raise FileNotFoundError(f"Missing {stem} ({', '.join(sorted(extensions))}) beside the script")
        return matches[0] if matches else None

    def camera_files(angle, supplied):
        if supplied:
            return [Path(p).expanduser().resolve() for p in supplied]
        stem = f"cam_{angle.lower()}"
        single = one(stem, {".mp4", ".mov"}, required=False)
        numbered = {}
        for p in files:
            match = re.fullmatch(stem + r"_part(\d+)", p.stem, flags=re.IGNORECASE)
            if match and p.suffix.lower() in {".mp4", ".mov"}:
                n = int(match.group(1))
                if n in numbered:
                    raise ValueError(f"Multiple versions of Camera {angle} part {n}: "
                                     f"{numbered[n].name}, {p.name}")
                numbered[n] = p
        if single and numbered:
            raise ValueError(f"Found both {stem} and {stem}_part files. Select files explicitly "
                             f"with --cam-{angle.lower()} or keep only the intended inputs.")
        inputs = [single] if single else [numbered[n] for n in sorted(numbered)]
        if not inputs:
            raise FileNotFoundError(f"Need {stem}.mp4 / {stem}.MOV or numbered {stem}_part1 "
                                    f"files beside the script; alternatively use --cam-{angle.lower()} PATH")
        return inputs

    bounce = Path(audio).expanduser().resolve() if audio else one("audio_bounce", {".wav"})
    a_inputs, b_inputs = camera_files("A", cam_a), camera_files("B", cam_b)
    if bounce.suffix.lower() != ".wav":
        raise ValueError("The audio bounce must be a .wav file")
    for p in [bounce] + a_inputs + b_inputs:
        if not p.is_file():
            raise FileNotFoundError(f"Input does not exist or is not a file: {p}")
    for p in a_inputs + b_inputs:
        if p.suffix.lower() not in {".mov", ".mp4"}:
            raise ValueError(f"Camera inputs must be .mp4 or .MOV: {p}")
    if len(set(a_inputs+b_inputs)) != len(a_inputs+b_inputs):
        raise ValueError("The same camera recording cannot be selected more than once")
    return bounce, a_inputs, b_inputs


def validate_framing(framing):
    """Validate a fixed source-frame composition; no crop animation is added."""
    if not isinstance(framing, dict):
        raise ValueError("Clip framing must be an object")
    mode = framing.get("mode", "fit")
    if mode not in ("fit", "crop"):
        raise ValueError("Clip framing mode must be fit or crop")
    centre = framing.get("center", [0.5, 0.5])
    if not isinstance(centre, (list, tuple)) or len(centre) != 2:
        raise ValueError("Clip framing center needs two values: X and Y")
    try:
        centre = [float(v) for v in centre]
        zoom = float(framing.get("zoom", 1))
    except (TypeError, ValueError):
        raise ValueError("Crop center and zoom must be numbers") from None
    if any(not math.isfinite(v) or not 0 <= v <= 1 for v in centre):
        raise ValueError("Crop center values must be finite and between 0 and 1")
    if not math.isfinite(zoom) or not 1 <= zoom <= 8:
        raise ValueError("Fixed crop zoom must be between 1 and 8")
    return {"mode": mode, "center": centre, "zoom": zoom}


def load_project(path):
    """Return validated camera/clip definitions and exact timeline overrides."""
    manifest_path = Path(path).expanduser().resolve()
    project = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(project, dict) or not isinstance(project.get("cameras"), list) or not project["cameras"]:
        raise ValueError("A project needs a nonempty cameras list")
    definitions, ids, paths, names = [], set(), set(), set()
    for camera in project["cameras"]:
        if not isinstance(camera, dict):
            raise ValueError("Each project camera must be an object")
        ident = str(camera.get("id", "")).strip()
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,31}", ident) or ident.upper() == "BLACK" or ident in ids:
            raise ValueError("Camera IDs must be unique names such as A, B or Crowd; BLACK is reserved")
        ids.add(ident)
        clips = camera.get("clips")
        if not isinstance(clips, list) or not clips:
            raise ValueError(f"Camera {ident} needs at least one clip")
        clean_clips = []
        for clip in clips:
            if not isinstance(clip, dict) or not isinstance(clip.get("path"), str) or not clip["path"].strip():
                raise ValueError(f"Each clip for {ident} needs a file path")
            source = Path(clip["path"]).expanduser()
            source = (source if source.is_absolute() else manifest_path.parent/source).resolve()
            if not source.is_file() or source.suffix.lower() not in {".mov", ".mp4"}:
                raise ValueError(f"Camera clip must be an existing MOV or MP4 file: {source}")
            if source in paths:
                raise ValueError("The same camera recording cannot be selected more than once")
            paths.add(source)
            names.add(source.name)
            clean_clips.append({"path": str(source), "framing": validate_framing(clip.get("framing", {"mode": "fit"}))})
        definitions.append({"id": ident, "label": str(camera.get("label") or ident)[:100], "clips": clean_clips})
    raw_overrides = project.get("shot_overrides", [])
    if not isinstance(raw_overrides, list):
        raise ValueError("Project shot_overrides must be a list")
    overrides = []
    for item in raw_overrides:
        if not isinstance(item, dict):
            raise ValueError("Each shot override must be an object")
        try:
            start, end = float(item["start"]), float(item["end"])
        except (KeyError, TypeError, ValueError):
            raise ValueError("Each shot override needs numeric start and end seconds") from None
        ident = str(item.get("camera_id", ""))
        if not math.isfinite(start) or not math.isfinite(end) or not 0 <= start < end:
            raise ValueError("Shot overrides require finite times with 0 <= start < end")
        if ident not in ids:
            raise ValueError(f"Unknown shot override camera: {ident}")
        clean = {"start": start, "end": end, "camera_id": ident}
        if item.get("source_path"):
            if not isinstance(item["source_path"], str):
                raise ValueError("A shot override source_path must be a file path string")
            source = Path(item["source_path"]).expanduser()
            source = (source if source.is_absolute() else manifest_path.parent/source).resolve()
            camera = next(c for c in definitions if c["id"] == ident)
            if str(source) not in {c["path"] for c in camera["clips"]}:
                raise ValueError("An exact shot override clip must belong to its selected camera")
            clean["source_path"] = str(source)
        overrides.append(clean)
    overrides.sort(key=lambda o: o["start"])
    if any(b["start"] < a["end"] for a, b in zip(overrides, overrides[1:])):
        raise ValueError("Shot overrides cannot overlap")
    return definitions, overrides


def synchronise(camera, reference, work, offsets, drifts, allow_drift):
    name = camera.path.name
    key = str(camera.path) if str(camera.path) in offsets or str(camera.path) in drifts else name
    if key in offsets:
        camera.sync_method = "manual"
        camera.offset = offsets[key]
        camera.rate = 1 + drifts.get(key, 0) / 1e6
        print(f"{name}: using manual sync")
    else:
        if key in drifts:
            raise ValueError(f"--drift-ppm for {name} also requires --offset")
        if not camera.has_audio:
            raise RuntimeError(f"{name} has no audio; supply --offset {name}=SECONDS")
        print(f"Syncing {name} at {SR} Hz …", flush=True)
        samples = extract_audio(camera.path, work / (hashlib.sha256(str(camera.path).encode()).hexdigest()[:16] + ".f32"))
        length = min(12 * SR, len(samples)//3, len(reference)//3)
        if length < 2 * SR:
            raise RuntimeError(f"{name}: recording too short for reliable automatic sync; use --offset")
        def find_matches(window):
            starts = np.unique(np.linspace(0, len(samples)-window, 7).astype(int))
            matches = []
            for start in starts:
                bounce_start, score = match_anchor(reference, samples[start:start+window])
                # Match the window centre: drift smears the edges of a long template.
                x = (start + window/2) / SR
                y = bounce_start + window/2 / SR
                matches.append((x, y, score))
                print(f"  audio {x:9.3f}s -> bounce {y:9.3f}s; correlation {score:.3f}", flush=True)
            return matches

        matches = find_matches(length)
        try:
            audio_offset, camera.rate, count = fit_sync(matches, allow_drift)
        except RuntimeError:
            if length <= 2*SR:
                raise
            # A small clock-rate difference can decorrelate a long waveform
            # window. Shorter anchors tolerate this while consensus across seven
            # distant points still checks the identity and timing of the match.
            print("  Retrying with 2-second anchors to tolerate clock drift …", flush=True)
            matches = find_matches(2*SR)
            audio_offset, camera.rate, count = fit_sync(matches, allow_drift)
        # Camera source time is measured from its first video frame, not audio.
        camera.offset = audio_offset + camera.rate * (camera.video_start-camera.audio_start)
        camera.matched_anchors = count
        print(f"  {count}/{len(matches)} consistent anchors")
    ppm = (camera.rate - 1) * 1e6
    print(f"  OFFSET {camera.offset:+.6f}s; clock correction {ppm:+.2f} ppm")
    print(f"  First video frame occurs at bounce {camera.offset:.3f}s; "
          f"coverage ends at {camera.offset + camera.rate*camera.duration:.3f}s")


def seconds(text):
    result = 0.0
    for part in str(text).split(":"):
        result = result*60 + float(part)
    if not math.isfinite(result) or result < 0:
        raise argparse.ArgumentTypeError("Times must be finite and nonnegative")
    return result


def time_range(text):
    try:
        a, b = map(seconds, text.split(","))
        if b <= a:
            raise ValueError()
        return a, b
    except (ValueError, argparse.ArgumentTypeError):
        raise argparse.ArgumentTypeError("Use START,END, e.g. 60,90 or 00:01:00,00:01:30")


def assignments(items):
    result = {}
    for item in items:
        if "=" not in item:
            raise ValueError("Sync overrides must be FILENAME=NUMBER")
        name, value = item.rsplit("=", 1)
        if not name or name in result:
            raise ValueError(f"Missing or repeated override filename: {name}")
        result[name] = float(value)
        if not math.isfinite(result[name]):
            raise ValueError("Offsets and drift values must be finite")
    return result


def resolve_sync_assignments(items, paths):
    """A unique filename or full source path can identify a sync override."""
    result = {}
    for key, value in assignments(items).items():
        exact = Path(key).expanduser().resolve()
        if (Path(key).is_absolute() or "/" in key or key.startswith("~")) and exact in paths:
            source = exact
        else:
            matches = [p for p in paths if p.name == key]
            if len(matches) > 1:
                raise ValueError(f"Ambiguous sync filename {key}; use the full source path before =")
            if not matches:
                raise ValueError(f"Sync override does not match a camera input: {key}")
            source = matches[0]
        if str(source) in result:
            raise ValueError(f"Repeated sync override for {source}")
        result[str(source)] = value
    return result


def energy_sections(reference, duration):
    # One-second blocks, smoothed over five seconds: suggestions, not beat/onset
    # or semantic drop detection. A heavily limited mix may produce none.
    count = len(reference)//SR
    if count < 30:
        return [], []
    rms = np.array([np.sqrt(np.mean(np.asarray(reference[i*SR:(i+1)*SR])**2))
                    for i in range(count)])
    energy = ndimage.uniform_filter1d(20*np.log10(np.maximum(rms, 1e-8)), size=5)
    low, high = np.quantile(energy, [0.25, 0.65])
    if high-low < 1.5:
        return [], []

    def regions(mask, minimum):
        edges = np.diff(np.r_[False, mask, False].astype(int))
        return [(float(a), min(float(b), duration))
                for a, b in zip(np.flatnonzero(edges == 1), np.flatnonzero(edges == -1))
                if b-a >= minimum]

    return regions(energy >= high, 8), regions(energy <= low, 15)


@dataclass
class Shot:
    start: int
    end: int
    camera: int | None
    reason: str


def choose_camera(cameras, angle, frame):
    available = [i for i, c in enumerate(cameras)
                 if c.angle == angle and c.first <= frame < c.last]
    # In overlaps, prefer the part with the longest remaining coverage.
    return max(available, key=lambda i: (cameras[i].last, -i)) if available else None


def plan_once(cameras, total, fps, drops, breakdowns, activities, rng, a_bias, cut_scale=1.0,
              main_camera="A", main_hold=(20, 60), cutaway_hold=(4, 12),
              drop_hold=(3, 6), breakdown_hold=(15, 30)):
    boundaries = sorted({0, total} | {min(total, max(0, round(t*fps)))
                        for a, b in drops+breakdowns for t in (a, b)})
    shots = []
    frame = 0
    angle_ids = list(dict.fromkeys(c.angle for c in cameras))

    def alternative(angle, at, prefer_main=False):
        if prefer_main and main_camera != angle and choose_camera(cameras, main_camera, at) is not None:
            return main_camera
        others = [ident for ident in angle_ids if ident != angle]
        available = [ident for ident in others if choose_camera(cameras, ident, at) is not None]
        pool = available or others or [angle]
        # No RNG draw for a sole alternative: preserve the legacy two-camera seed.
        return pool[0] if len(pool) == 1 else rng.choice(pool)

    desired = main_camera
    last_mode = None
    while frame < total:
        t = frame/fps
        mode = ("breakdown" if any(a <= t < b for a, b in breakdowns)
                else "drop" if any(a <= t < b for a, b in drops) else "normal")
        if mode != last_mode:
            desired = main_camera  # always settle back on home angle
        if mode == "breakdown":
            desired = main_camera
        i = choose_camera(cameras, desired, frame)
        fallback = False
        if i is None:
            i = choose_camera(cameras, alternative(desired, frame, prefer_main=True), frame)
            fallback = True
        boundary = next(b for b in boundaries if b > frame)
        if i is None:
            end = min([boundary] + [c.first for c in cameras if c.first > frame])
            if shots and shots[-1].camera is None:
                shots[-1].end = end
            else:
                shots.append(Shot(frame, end, None, "no camera coverage; black"))
            frame, last_mode = end, mode
            continue
        angle = cameras[i].angle
        if mode == "drop":
            hold = rng.uniform(*drop_hold)
        elif mode == "breakdown":
            hold = rng.uniform(*breakdown_hold)
        elif angle == main_camera:
            hold = main_hold[0] + (main_hold[1]-main_hold[0]) * rng.betavariate(1, a_bias)
        else:
            hold = rng.uniform(*cutaway_hold)
        hold *= cut_scale
        # Bias a normal cutaway's entry toward supplied action timestamps when
        # they fit the main hold range; unmarked cutaways remain random.
        if mode == "normal" and angle == main_camera and not fallback:
            actions = [a for a in activities if t+main_hold[0]*cut_scale <= a
                       <= min(t+main_hold[1]*cut_scale, boundary/fps)]
            if actions:
                hold = min(actions, key=lambda a: abs(a-t-hold))-t
        end = min(total, boundary, cameras[i].last, frame + max(1, round(hold*fps)))
        if fallback:
            returns = [c.first for c in cameras if c.angle == desired and frame < c.first < end]
            if returns:
                end = min(returns)
        reason = mode + ("; coverage fallback" if fallback else "")
        # Adjacent identical sources are one hold, not a fictitious cut. This
        # intentionally keeps a whole breakdown on the home angle.
        if shots and shots[-1].camera == i and shots[-1].end == frame:
            shots[-1].end = end
            if reason not in shots[-1].reason:
                shots[-1].reason += "; " + reason
        else:
            shots.append(Shot(frame, end, i, reason))
        frame = end
        desired = main_camera if angle != main_camera else alternative(main_camera, frame)
        last_mode = mode
    return shots


def statistics(shots, cameras, fps):
    duration = shots[-1].end / fps
    a_time = sum((s.end-s.start)/fps for s in shots
                 if s.camera is not None and cameras[s.camera].angle == "A")
    black = sum((s.end-s.start)/fps for s in shots if s.camera is None)
    return a_time / max(duration-black, 1e-9), duration/max(len(shots)-1, 1), black


def make_plan(cameras, total, fps, drops, breakdowns, activities, seed, cut_scale=1.0,
              main_camera="A", main_share=0.70, main_hold=(20, 60), cutaway_hold=(4, 12),
              drop_hold=(3, 6), breakdown_hold=(15, 30)):
    rng = random.Random(seed)
    candidates = []
    for _ in range(160):
        shots = plan_once(cameras, total, fps, drops, breakdowns, activities,
                          rng, rng.uniform(1, 12), cut_scale, main_camera, main_hold,
                          cutaway_hold, drop_hold, breakdown_hold)
        share, interval, _ = statistics(shots, cameras, fps)
        outside = max(10*cut_scale-interval, 0, interval-15*cut_scale)
        primary_share = camera_shares(shots, cameras).get(main_camera, 0.0)
        cost = ((primary_share-main_share)/0.05)**2 + (outside/(3*cut_scale))**2
        candidates.append((cost, shots))
    return min(candidates, key=lambda item: item[0])[1]


def timecode(t):
    ms = round(t*1000)
    hours, ms = divmod(ms, 3600000)
    minutes, ms = divmod(ms, 60000)
    seconds_, ms = divmod(ms, 1000)
    return f"{hours:02}:{minutes:02}:{seconds_:02}.{ms:03}"


def output_size(mode):
    return (HEIGHT, WIDTH) if mode == "vertical" else (WIDTH, HEIGHT)


def crop_filter(angle, centre, mode="horizontal", a_centre=(0.5, 0.5)):
    # FFmpeg autorotates phone footage before these filters.
    width, height = output_size(mode)
    cropped_angle = "A" if mode == "vertical" else "B"
    if angle == cropped_angle:
        x, y = a_centre if mode == "vertical" else centre
        crop = (f"crop=w='trunc(min(iw,ih*{width}/{height})/2)*2':"
                f"h='trunc(ow*{height}/{width}/2)*2':"
                f"x='trunc(max(0,min(iw-ow,iw*{x}-ow/2))/2)*2':"
                f"y='trunc(max(0,min(ih-oh,ih*{y}-oh/2))/2)*2',")
        return crop + f"scale={width}:{height}:flags=lanczos,setsar=1"
    # Preserve full A horizontally or full B vertically. Nonstandard input
    # ratios get fixed padding, without stretching or silently cropping.
    return (f"scale={width}:{height}:force_original_aspect_ratio=decrease:"
            f"force_divisible_by=2,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,setsar=1")


def framing_filter(framing, mode="horizontal"):
    """Fit the full source, or apply a static aspect crop with a fixed zoom."""
    framing = validate_framing(framing)
    width, height = output_size(mode)
    if framing["mode"] == "fit":
        return (f"scale={width}:{height}:force_original_aspect_ratio=decrease:"
                f"force_divisible_by=2,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,setsar=1")
    x, y = framing["center"]
    zoom = framing["zoom"]
    return (f"crop=w='max(2,trunc(min(iw,ih*{width}/{height})/{zoom}/2)*2)':"
            f"h='max(2,trunc(ow*{height}/{width}/2)*2)':"
            f"x='trunc(max(0,min(iw-ow,iw*{x}-ow/2))/2)*2':"
            f"y='trunc(max(0,min(ih-oh,ih*{y}-oh/2))/2)*2',"
            f"scale={width}:{height}:flags=lanczos,setsar=1")


def camera_filter(camera, args):
    return (framing_filter(camera.framing, args.mode) if camera.framing is not None
            else crop_filter(camera.angle, args.b_center, args.mode, args.a_center))


def camera_shares(shots, cameras):
    frames = {c.angle: 0 for c in cameras}
    for shot in shots:
        if shot.camera is not None:
            frames[cameras[shot.camera].angle] += shot.end-shot.start
    covered = sum(frames.values())
    return {angle: value/max(covered, 1) for angle, value in frames.items()}


def apply_shot_overrides(shots, cameras, overrides, fps, duration):
    """Replace only requested frame-grid intervals; preserve the seeded remainder."""
    if not overrides:
        return shots
    total = shots[-1].end
    forced = []
    previous_end = 0
    for item in overrides:
        if item["end"] > duration+1e-7:
            raise ValueError("A shot override extends beyond the audio bounce")
        start = round(item["start"]*fps)
        end = total if abs(item["end"]-duration) < 1e-7 else round(item["end"]*fps)
        if not 0 <= start < end <= total:
            raise ValueError("Every shot override must cover at least one output frame within the bounce")
        if start < previous_end:
            raise ValueError("Shot overrides overlap after frame-grid rounding")
        previous_end = end
        frame = start
        while frame < end:
            ident = item["camera_id"]
            if item.get("source_path"):
                index = next((i for i, c in enumerate(cameras)
                              if c.angle == ident and str(c.path) == item["source_path"]
                              and c.first <= frame < c.last), None)
            else:
                index = choose_camera(cameras, ident, frame)
            if index is None:
                raise ValueError(f"Shot override for {ident} lacks synced footage at {timecode(frame/fps)}; "
                                 "adjust the range or choose another clip")
            segment_end = min(end, cameras[index].last)
            forced.append(Shot(frame, segment_end, index, "manual shot override"))
            frame = segment_end
    boundaries = sorted({s.start for s in shots+forced} | {s.end for s in shots+forced})
    result = []
    normal_index = forced_index = 0
    for start, end in zip(boundaries, boundaries[1:]):
        while normal_index+1 < len(shots) and shots[normal_index].end <= start:
            normal_index += 1
        while forced_index < len(forced) and forced[forced_index].end <= start:
            forced_index += 1
        selected = (forced[forced_index] if forced_index < len(forced)
                    and forced[forced_index].start <= start < forced[forced_index].end
                    else shots[normal_index])
        if result and result[-1].camera == selected.camera and result[-1].reason == selected.reason:
            result[-1].end = end
        else:
            result.append(Shot(start, end, selected.camera, selected.reason))
    return result


def write_cut_list(path, shots, cameras, duration, args, drops, breakdowns):
    share, interval, black = statistics(shots, cameras, args.fps)
    width, height = output_size(args.mode)
    shares = camera_shares(shots, cameras)
    crop_note = ("Each source uses its saved, fixed project framing" if any(c.framing is not None for c in cameras)
                 else f"Fixed A crop centre: {args.a_center}; B retains its full frame"
                 if args.mode == "vertical" else f"Fixed B crop centre: {args.b_center}")
    lines = [f"Seed: {args.seed}; mode: {args.mode}; cut scale: {args.cut_scale}; "
             f"output: {width}x{height} @ {args.fps} fps; main camera: {args.main_camera}",
             f"Bounce duration: {duration:.9f}s; timecodes: HH:MM:SS.mmm (bounce timeline)",
             "Camera share excluding black: " + ", ".join(f"{key} {value:.1%}" for key, value in shares.items())
             + f"; seconds per cut: {interval:.2f}; black: {black:.3f}s",
             "Offset convention: bounce_time = offset + rate * video_source_time",
             crop_note,
             f"Drop/peak ranges: {drops}", f"Breakdown ranges: {breakdowns}"]
    for c in cameras:
        lines.append(f"SYNC CAM_{c.angle} {c.path}: offset={c.offset:+.6f}s, rate={c.rate:.10f}, "
                     f"drift={(c.rate-1)*1e6:+.2f}ppm")
    lines += ["", "#  IN -> OUT | ANGLE | FILE | SOURCE IN -> OUT | REASON"]
    for n, s in enumerate(shots, 1):
        end = min(s.end/args.fps, duration)
        prefix = f"{n:04}  {timecode(s.start/args.fps)} -> {timecode(end)}"
        if s.camera is None:
            lines.append(f"{prefix} | BLACK | - | - | {s.reason}")
        else:
            c = cameras[s.camera]
            source_in = (s.start/args.fps-c.offset)/c.rate
            source_out = (end-c.offset)/c.rate
            lines.append(f"{prefix} | CAM_{c.angle} | {c.path} | "
                         f"{timecode(source_in)} -> {timecode(source_out)} | {s.reason}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(lines[2])
    primary_share = shares.get(args.main_camera, 0.0)
    if abs(primary_share-args.main_share) > 0.05 or not 10*args.cut_scale <= interval <= 15*args.cut_scale:
        print("NOTE: coverage and hold/section rules prevent reaching all soft targets.")
    if black:
        print(f"WARNING: neither camera covers some times; these are BLACK in {path.name}.")


def render(shots, cameras, bounce, duration, work, output, args):
    width, height = output_size(args.mode)
    segment_paths = []
    for n, s in enumerate(shots, 1):
        frames = s.end-s.start
        length = frames/args.fps
        target = work / f"shot_{n:06}.mp4"
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
        if s.camera is None:
            cmd += ["-f", "lavfi", "-i", f"color=c=black:s={width}x{height}:r={args.fps}"]
            filters = "setsar=1"
            label = "BLACK"
        else:
            c = cameras[s.camera]
            source_start = max(0.0, (s.start/args.fps-c.offset)/c.rate)
            # Keep original timestamps and subtract the EXACT desired source PTS.
            # Resetting to the first decoded frame separately in every shot would
            # introduce a fresh fractional-frame shift at every cut.
            # Retain the frame straddling the requested source time. Seeking and
            # trimming exactly at source_start can discard that frame, including
            # the only available frame when a shot begins at the end of a part.
            # Negative relative PTS let fps select the correct frame at time zero.
            preroll_start = max(0.0, source_start-1.0)
            seek = max(0.0, preroll_start+c.video_start-c.format_start)
            cmd += ["-copyts", "-ss", f"{seek:.9f}",
                    "-t", f"{source_start-preroll_start+length/c.rate+1:.9f}", "-i", c.path]
            filters = (f"trim=start={preroll_start+c.video_start:.9f}:"
                       f"end={source_start+c.video_start+length/c.rate:.9f},"
                       f"setpts=(PTS-({source_start+c.video_start:.9f})/TB)*{c.rate:.12f},"
                       + camera_filter(c, args))
            label = c.path.name
        # A global frame grid avoids accumulated per-shot rounding drift. A final
        # subframe/decoder boundary may need one repeated frame, never a long hold.
        filters += (f",fps={args.fps}:start_time=0:round=near,"
                    f"tpad=stop_mode=clone:stop_duration={2/args.fps:.9f},"
                    f"trim=end_frame={frames},setpts=N/({args.fps}*TB),format=yuv420p")
        cmd += ["-map", "0:v:0", "-an", "-sn", "-dn", "-vf", filters,
                "-frames:v", frames, "-c:v", "libx264", "-preset", args.preset,
                "-crf", args.crf, "-pix_fmt", "yuv420p", "-bf", "0",
                "-video_track_timescale", "90000", "-map_metadata", "-1", target]
        print(f"Rendering {n}/{len(shots)}: {timecode(s.start/args.fps)} {label} ({length:.2f}s)", flush=True)
        run(cmd)
        video = next((v for v in probe(target)["streams"] if v["codec_type"] == "video"), None)
        if video is None or int(video.get("nb_frames", 0)) != frames:
            raise RuntimeError(f"Shot {n} did not produce {frames} frames; source may have a video gap.")
        segment_paths.append(target)
    listing = work / "concat.txt"
    # Safe generated relative filenames work even if the user's folder has quotes.
    listing.write_text("".join(f"file '{p.name}'\n" for p in segment_paths), encoding="utf-8")
    assembled = work / "multicam_cut.mp4"
    print("Concatenating and adding the audio bounce …", flush=True)
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
         "-f", "concat", "-safe", "1", "-i", listing, "-i", bounce,
         "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy",
         "-af", f"asetpts=PTS-STARTPTS,atrim=duration={duration:.9f}",
         "-c:a", "aac", "-b:a", "320k", "-t", f"{duration:.9f}",
         "-map_metadata", "-1", "-movflags", "+faststart", assembled])
    info = probe(assembled)
    streams = info["streams"]
    videos = [s for s in streams if s["codec_type"] == "video"]
    audios = [s for s in streams if s["codec_type"] == "audio"]
    if (len(videos) != 1 or len(audios) != 1 or videos[0]["codec_name"] != "h264"
            or videos[0]["width"] != width or videos[0]["height"] != height
            or abs(stream_duration(info, videos[0])-duration) > 1/args.fps+0.005
            or abs(stream_duration(info, audios[0])-duration) > 0.05):
        raise RuntimeError("Final output failed stream/duration verification")
    assembled.replace(output)  # old output is only replaced after successful validation


def write_report(path, shots, cameras, bounce, duration, args, drops, breakdowns,
                 output, cut_list, previews, status):
    """Versioned, machine-readable plan used by the local web interface."""
    a_share, interval, black = statistics(shots, cameras, args.fps)
    covered = sum(s.end-s.start for s in shots if s.camera is not None)
    b_frames = sum(s.end-s.start for s in shots
                   if s.camera is not None and cameras[s.camera].angle == "B")
    b_share = b_frames / max(covered, 1)
    shares = camera_shares(shots, cameras)
    width, height = output_size(args.mode)
    shot_rows = []
    for n, shot in enumerate(shots, 1):
        start, end = shot.start/args.fps, min(duration, shot.end/args.fps)
        c = cameras[shot.camera] if shot.camera is not None else None
        shot_rows.append({"index": n, "start_seconds": start, "end_seconds": end,
                          "angle": c.angle if c else "BLACK",
                          "source_path": str(c.path) if c else None,
                          "source_in_seconds": max(0, (start-c.offset)/c.rate) if c else None,
                          "source_out_seconds": max(0, (end-c.offset)/c.rate) if c else None,
                          "reason": shot.reason})
    report = {
        "schema_version": 1, "status": status,
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "settings": vars(args), "duration_seconds": duration,
        "shot_overrides": getattr(args, "shot_overrides", []),
        "fps": args.fps, "width": width, "height": height, "audio": str(bounce),
        "sections": {"drops": drops, "breakdowns": breakdowns, "activities": args.activity},
        "sync": [{"angle": c.angle, "source_path": str(c.path), "filename": c.path.name,
                  "label": c.label or c.angle, "framing": c.framing,
                  "offset_seconds": c.offset, "rate": c.rate, "drift_ppm": (c.rate-1)*1e6,
                  "coverage_start_seconds": c.first/args.fps,
                  "coverage_end_seconds": min(duration, c.last/args.fps),
                  "source_duration_seconds": c.duration, "method": c.sync_method,
                  "matched_anchors": c.matched_anchors} for c in cameras],
        "shots": shot_rows,
        "stats": {"a_share": a_share, "b_share": b_share,
                  "main_share": shares.get(args.main_camera, 0.0), "camera_shares": shares,
                  "average_cut_seconds": interval, "black_seconds": black,
                  "shot_count": len(shots), "cut_count": max(0, len(shots)-1)},
        "outputs": {"video": str(output) if status == "rendered" else None,
                    "planned_video": str(output), "cut_list": str(cut_list), "report": str(path),
                    "previews": [{"angle": c.angle, "source_path": str(c.path), "path": str(p)}
                                 for c, p in zip(cameras, previews)]},
    }
    # Replace only complete JSON, so polling clients never read a partial report.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     prefix=".multicam_report_", suffix=".json", delete=False) as f:
        temporary = Path(f.name)
        try:
            json.dump(report, f, indent=2, allow_nan=False)
            f.write("\n")
            f.close()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--mode", choices=["horizontal", "vertical"], default="horizontal")
    parser.add_argument("--main-camera", default=None, metavar="ID",
                        help="Home angle for long holds and breakdowns; crop identities stay unchanged")
    parser.add_argument("--project", metavar="PATH", help="JSON camera project with arbitrary cameras, per-clip framing and shot overrides")
    parser.add_argument("--cam-a", action="append", metavar="PATH", help="Camera A file; repeat for parts")
    parser.add_argument("--cam-b", action="append", metavar="PATH", help="Camera B file; repeat for parts")
    parser.add_argument("--audio", metavar="PATH", help="Audio bounce WAV; defaults to audio_bounce.wav")
    parser.add_argument("--output-dir", metavar="PATH", help="Output and scratch folder; defaults beside script")
    parser.add_argument("--output-name", metavar="BASE", help="Video filename base, optionally ending in .mp4")
    parser.add_argument("--report-json", metavar="PATH", help="JSON report path; defaults to report_MODE.json")
    parser.add_argument("--main-hold", type=float, nargs=2, default=[20, 60], metavar=("MIN", "MAX"))
    parser.add_argument("--cutaway-hold", type=float, nargs=2, default=[4, 12], metavar=("MIN", "MAX"))
    parser.add_argument("--drop-hold", type=float, nargs=2, default=[3, 6], metavar=("MIN", "MAX"))
    parser.add_argument("--breakdown-hold", type=float, nargs=2, default=[15, 30], metavar=("MIN", "MAX"))
    parser.add_argument("--main-share", type=float, default=0.7, help="Soft main-angle screen-time target, 0 to 1")
    parser.add_argument("--cut-scale", type=float, default=1.0)
    parser.add_argument("--a-center", type=float, nargs=2, default=[0.5, 0.5], metavar=("X", "Y"))
    parser.add_argument("--fps", type=int, choices=[24, 25, 30, 50, 60], default=30)
    parser.add_argument("--b-center", type=float, nargs=2, default=[0.5, 0.72], metavar=("X", "Y"))
    parser.add_argument("--drop", type=time_range, action="append", default=[])
    parser.add_argument("--breakdown", type=time_range, action="append", default=[])
    parser.add_argument("--activity", type=seconds, action="append", default=[])
    parser.add_argument("--no-auto-sections", action="store_true")
    parser.add_argument("--no-drift", action="store_true")
    parser.add_argument("--offset", action="append", default=[])
    parser.add_argument("--drift-ppm", action="append", default=[])
    parser.add_argument("--plan-only", action="store_true")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--crf", type=int, choices=range(0, 52), default=18, metavar="0-51")
    parser.add_argument("--preset", choices=["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow"], default="medium")
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if not math.isfinite(args.cut_scale) or not 0 < args.cut_scale <= 1000:
        parser.error("--cut-scale must be finite, greater than zero and at most 1000")
    if not math.isfinite(args.main_share) or not 0 <= args.main_share <= 1:
        parser.error("--main-share must be a finite number between 0 and 1")
    for option in ("main_hold", "cutaway_hold", "drop_hold", "breakdown_hold"):
        low, high = getattr(args, option)
        if not all(math.isfinite(v) for v in (low, high)) or not 0 < low <= high <= 3600:
            parser.error(f"--{option.replace('_', '-')} requires 0 < MIN <= MAX <= 3600 seconds")
        if low*args.cut_scale < 1/args.fps:
            parser.error(f"--{option.replace('_', '-')} MIN times --cut-scale must be at least one output frame")
    if any(not 0 <= v <= 1 for v in args.a_center):
        parser.error("--a-center values must be finite and between 0 and 1")
    if any(not 0 <= v <= 1 for v in args.b_center):
        parser.error("--b-center values must be finite and between 0 and 1")
    for binary in ("ffmpeg", "ffprobe"):
        if not shutil.which(binary):
            raise RuntimeError(f"Missing {binary}. Install FFmpeg (macOS: brew install ffmpeg; "
                               "Windows: winget install Gyan.FFmpeg) and make sure it is on PATH")
    folder = Path(__file__).resolve().parent
    definitions = None
    shot_overrides = []
    if args.project:
        if args.cam_a or args.cam_b:
            parser.error("Use --project or --cam-a/--cam-b, not both")
        definitions, shot_overrides = load_project(args.project)
        inputs = [Path(clip["path"]) for camera in definitions for clip in camera["clips"]]
        ids = [camera["id"] for camera in definitions]
        args.main_camera = args.main_camera or ids[0]
        if args.main_camera not in ids:
            parser.error("--main-camera must match a camera ID in the project")
        if args.audio:
            bounce = Path(args.audio).expanduser().resolve()
        else:
            matches = [p for p in folder.iterdir() if p.is_file()
                       and p.stem.lower() == "audio_bounce" and p.suffix.lower() == ".wav"]
            if len(matches) != 1:
                raise ValueError("Select the project's audio bounce with --audio PATH")
            bounce = matches[0]
        if not bounce.is_file() or bounce.suffix.lower() != ".wav":
            raise ValueError("The audio bounce must be an existing WAV file")
    else:
        bounce, a_inputs, b_inputs = discover_inputs(folder, args.audio, args.cam_a, args.cam_b)
        inputs = a_inputs+b_inputs
        args.main_camera = (args.main_camera or "A").upper()
        if args.main_camera not in ("A", "B"):
            parser.error("Without --project, --main-camera must be A or B")
    args.shot_overrides = shot_overrides
    offsets = resolve_sync_assignments(args.offset, inputs)
    drifts = resolve_sync_assignments(args.drift_ppm, inputs)
    if drifts.keys() - offsets.keys():
        raise ValueError("Every --drift-ppm override also requires --offset for the same file")
    if any(abs(v) > MAX_DRIFT_PPM for v in drifts.values()):
        raise ValueError(f"Clock correction must be within +/-{MAX_DRIFT_PPM} ppm")
    output_dir = Path(args.output_dir).expanduser().resolve() if args.output_dir else folder
    suffix = "_vertical" if args.mode == "vertical" else ""
    output_name = args.output_name or f"multicam_cut{suffix}"
    if output_name.lower().endswith(".mp4"):
        output_name = output_name[:-4]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,119}", output_name) or output_name.endswith((" ", ".")):
        raise ValueError("--output-name must be a filename, 1-120 letters/digits/spaces/._-; "
                         "start with a letter/digit and do not end with a dot or space")
    output = (output_dir / f"{output_name}.mp4").resolve()
    cut_list = (output_dir / f"cut_list{suffix}.txt").resolve()
    report_path = (Path(args.report_json).expanduser().resolve() if args.report_json
                   else (output_dir / f"report_{args.mode}.json").resolve())
    # Preview every source in both modes, so source identity is visible in the UI.
    preview_inputs = inputs
    stems = [p.stem.casefold() for p in preview_inputs]
    preview_prefixes = ([f"{camera['id']}_{index+1}_" for camera in definitions
                         for index, clip in enumerate(camera["clips"])] if definitions else [""]*len(inputs))
    if not definitions and len({p.name for p in inputs}) != len(inputs):
        preview_prefixes = [f"source_{index+1}_" for index in range(len(inputs))]
    previews = [(output_dir / (prefix+p.stem + ("_"+p.suffix[1:] if stems.count(p.stem.casefold()) > 1 else "")
                              + suffix + "_crop_preview.jpg")).resolve()
                for p, prefix in zip(preview_inputs, preview_prefixes)]
    all_outputs = [output, cut_list, report_path] + previews
    if len(set(str(p).casefold() for p in all_outputs)) != len(all_outputs):
        raise ValueError("Output paths collide: choose distinct movie, report and preview filenames")
    protected_inputs = [bounce]+inputs+([Path(args.project).expanduser().resolve()] if args.project else [])
    input_paths = {str(p.resolve()).casefold() for p in protected_inputs}
    if any(str(p).casefold() in input_paths
           or (p.exists() and any(p.samefile(source) for source in protected_inputs))
           for p in all_outputs):
        raise ValueError("An output would overwrite an input file; choose another output folder/name")
    protected = [cut_list, report_path] + previews + ([] if args.plan_only else [output])
    if not args.overwrite and any(p.exists() for p in protected):
        existing = next(p for p in protected if p.exists())
        raise FileExistsError(f"Output already exists: {existing}. Use --overwrite to replace it.")
    if any(p.exists() and not p.is_file() for p in all_outputs):
        raise ValueError("An output path refers to a directory; choose a different path")
    info = probe(bounce)
    audio = next((s for s in info["streams"] if s["codec_type"] == "audio"), None)
    if audio is None:
        raise ValueError(f"{bounce.name} has no audio stream")
    duration = stream_duration(info, audio)
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("Audio bounce has no positive finite duration")
    total = math.ceil(duration * args.fps - 1e-8)
    if definitions:
        cameras = []
        for definition in definitions:
            for clip in definition["clips"]:
                camera = read_camera(Path(clip["path"]), definition["id"])
                camera.label = definition["label"]
                camera.framing = clip["framing"]
                cameras.append(camera)
    else:
        cameras = [read_camera(p, "A") for p in a_inputs] + [read_camera(p, "B") for p in b_inputs]
    output_dir.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    # Scratch beside output enables atomic final replacement on the same disk.
    # Windows cancels with Ctrl+Break; handle it like Ctrl+C so scratch files are removed.
    if hasattr(os_signal, "SIGBREAK"):
        os_signal.signal(os_signal.SIGBREAK, os_signal.default_int_handler)
    with tempfile.TemporaryDirectory(prefix=".multicam_work_", dir=output_dir,
                                     ignore_cleanup_errors=True) as temp:
        work = Path(temp)
        print(f"Main camera: {args.main_camera}; target screen time: {args.main_share:.0%}; mode: {args.mode}", flush=True)
        print("Preparing audio bounce for correlation …", flush=True)
        reference = extract_audio(bounce, work / "bounce.f32")
        for c in cameras:
            synchronise(c, reference, work, offsets, drifts, not args.no_drift)
            c.first = max(0, min(total, math.ceil(c.offset * args.fps - 1e-7)))
            end = c.offset + c.rate*c.duration
            c.last = max(0, min(total, math.floor(end * args.fps + 1e-7)))
            if end >= duration-1e-7:
                c.last = total
        drops, breakdowns = args.drop, args.breakdown
        if not drops and not breakdowns and not args.no_auto_sections:
            print("Suggesting sections from audio energy; supply markers for precise drop timing.")
            drops, breakdowns = energy_sections(reference, duration)
        del reference  # release the memory map so Windows can delete the scratch folder
        drops = [(round(a*args.fps)/args.fps, round(b*args.fps)/args.fps) for a, b in drops]
        breakdowns = [(round(a*args.fps)/args.fps, round(b*args.fps)/args.fps) for a, b in breakdowns]
        shots = make_plan(cameras, total, args.fps, drops, breakdowns, args.activity, args.seed,
                          args.cut_scale, args.main_camera, args.main_share, args.main_hold,
                          args.cutaway_hold, args.drop_hold, args.breakdown_hold)
        shots = apply_shot_overrides(shots, cameras, shot_overrides, args.fps, duration)
        write_cut_list(cut_list, shots, cameras, duration, args, drops, breakdowns)
        pw, ph = (540, 960) if args.mode == "vertical" else (960, 540)
        for c, preview in zip(cameras, previews):
            run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                 "-ss", f"{min(3, c.duration/2):.6f}", "-i", c.path,
                 "-map", "0:v:0", "-an", "-vf",
                 camera_filter(c, args)+f",scale={pw}:{ph}",
                 "-frames:v", "1", "-update", "1", preview])
            print(f"Fixed crop preview: {preview}")
        write_report(report_path, shots, cameras, bounce, duration, args, drops, breakdowns,
                     output, cut_list, previews, "planned")
        if args.plan_only:
            print(f"Plan saved: {cut_list}\nReport: {report_path}\nRender with the same options, remove --plan-only and add --overwrite.")
        else:
            render(shots, cameras, bounce, duration, work, output, args)
            write_report(report_path, shots, cameras, bounce, duration, args, drops, breakdowns,
                         output, cut_list, previews, "rendered")
            print(f"Done: {output}\nCut list: {cut_list}\nReport: {report_path}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("\nCancelled; temporary render files removed.")
    except (RuntimeError, ValueError, OSError) as exc:
        sys.exit(f"ERROR: {exc}")
