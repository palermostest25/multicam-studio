#!/usr/bin/env python3
"""Multicam Studio UI demo: the full interface with only Python's standard library.

    python demo.py --open          (Windows: py demo.py --open)

No NumPy, SciPy, FFmpeg or virtual environment is needed. The demo creates a sample
project (three placeholder camera files and a generated WAV bounce), draws preview
frames as SVG, derives the waveform from the WAV and builds real-looking edit plans.
Everything works up to producing a video file: rendering, clip export and effects
stop with an explanation instead of writing a movie.
"""
from __future__ import annotations
import argparse
import array
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import random
import secrets
import sys
import time
import wave

import server

DEMO_BADGE = 'DEMO · NO RENDERING'
STOP_MESSAGE = ('Demo mode stops here. Rendering needs FFmpeg; run the full studio '
                '(server.py or Docker) to write video files.')
DEMO_MEDIA = {
    # name: (width, height, duration seconds, colour)
    'CamA_wide.mp4': (3840, 2160, 190.0, '#2c4f7c'),
    'CamB_booth_phone.mov': (2160, 3840, 185.0, '#6b2f5e'),
    'CamC_crowd.mp4': (1920, 1080, 120.0, '#2f6b4a'),
}
BOUNCE = 'master_bounce.wav'
PALETTE = ['#2c4f7c', '#6b2f5e', '#2f6b4a', '#7c5a2c', '#4a2f6b', '#2c6b7c']


# ---------------------------------------------------------------- sample media

def make_bounce(path, seconds=180, rate=11025):
    """A synthetic 124 BPM mix with an intro, two drops and a breakdown."""
    rng = random.Random(7)
    beat = 60 / 124
    kick = [math.sin(2*math.pi*(55+90*math.exp(-i/180))*i/rate)*math.exp(-i/900) for i in range(int(.18*rate))]
    samples = array.array('h')
    for n in range(int(seconds*rate)):
        t = n/rate
        section = (.35 if t < 30 else .7 if t < 60 else 1 if t < 90 else .25 if t < 120 else 1 if t < 160 else .45)
        value = 0.0
        position = int((t % beat)*rate)
        if section > .3 and position < len(kick):
            value += kick[position]*.8
        value += math.sin(2*math.pi*110*t)*.12*section           # bass
        if int(t/beat*2) % 2 and (t*2 % beat) < .03:            # off-beat hat
            value += (rng.random()-.5)*.5*section
        value += math.sin(2*math.pi*440*t + math.sin(t))*.05     # pad
        samples.append(int(max(-1, min(1, value*section))*30000))
    if sys.byteorder == 'big':
        samples.byteswap()
    with wave.open(str(path), 'wb') as out:
        out.setnchannels(1); out.setsampwidth(2); out.setframerate(rate)
        out.writeframes(samples.tobytes())


def prepare_media(folder):
    folder.mkdir(parents=True, exist_ok=True)
    (folder/'Exports').mkdir(exist_ok=True)
    for name in DEMO_MEDIA:
        target = folder/name
        if not target.exists():
            target.write_text('Placeholder recording for the Multicam Studio UI demo.\n', encoding='utf-8')
    if not (folder/BOUNCE).exists():
        print('Creating the sample audio bounce (first run only)…', flush=True)
        partial = folder/(BOUNCE+'.part')
        make_bounce(partial)
        partial.replace(folder/BOUNCE)


# ---------------------------------------------------------------- fake media info

def wav_info(path):
    try:
        with wave.open(str(path), 'rb') as w:
            return w.getnframes()/w.getframerate()
    except (wave.Error, EOFError, OSError):
        return None


def media_info(path):
    """Plausible metadata without FFprobe; stable for a given file."""
    path = Path(path)
    if path.suffix.lower() == '.wav':
        return {'duration': wav_info(path) or 180.0, 'width': None, 'height': None, 'has_audio': True}
    if path.name in DEMO_MEDIA:
        w, h, d, _ = DEMO_MEDIA[path.name]
    else:
        seed = int(hashlib.sha256(str(path).encode()).hexdigest()[:8], 16)
        w, h = (2160, 3840) if seed % 3 == 0 else (3840, 2160)
        d = 150.0 + seed % 90
    return {'duration': d, 'width': w, 'height': h, 'has_audio': True}


def ffprobe_json(path):
    """Stand-in for effects.probe, so clip and effects settings validate normally."""
    info = media_info(path)
    streams = [{'codec_type': 'audio', 'channels': 2, 'duration': str(info['duration'])}]
    if info['width']:
        streams.insert(0, {'codec_type': 'video', 'codec_name': 'h264', 'width': info['width'], 'height': info['height'],
                           'avg_frame_rate': '30/1', 'r_frame_rate': '30/1', 'duration': str(info['duration'])})
    return {'streams': streams, 'format': {'duration': str(info['duration'])}}


def colour(path):
    path = Path(path)
    if path.name in DEMO_MEDIA:
        return DEMO_MEDIA[path.name][3]
    return PALETTE[int(hashlib.sha256(str(path).encode()).hexdigest()[:4], 16) % len(PALETTE)]


def escape(text):
    return str(text).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def scene(path, at, w, h):
    """An illustrated 'camera frame' in source pixel coordinates."""
    base = colour(path)
    u = min(w, h)/100
    pulse = .5+.5*math.sin(at*2.1)
    booth_y = h*.62
    people = ''.join(
        f'<circle cx="{w*x:.0f}" cy="{h*.9:.0f}" r="{u*s:.0f}" fill="#0b0d10" opacity=".85"/>'
        for x, s in [(.08, 7), (.2, 8), (.33, 6.5), (.67, 7.5), (.8, 8.5), (.93, 6)])
    lights = ''.join(
        f'<polygon points="{w*x:.0f},0 {w*x-u*12:.0f},{h*.7:.0f} {w*x+u*12:.0f},{h*.7:.0f}" '
        f'fill="{c}" opacity="{.12+.18*((i+at) % 2 > 1)*pulse:.2f}"/>'
        for i, (x, c) in enumerate([(.2, '#e6b774'), (.5, '#8dcccf'), (.8, '#e67474')]))
    return (
        f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{base}"/>'
        f'<stop offset="1" stop-color="#07080a"/></linearGradient></defs>'
        f'<rect width="{w}" height="{h}" fill="url(#bg)"/>{lights}'
        # grid, so crops and zoom are easy to judge
        + ''.join(f'<line x1="{w*i/8:.0f}" y1="0" x2="{w*i/8:.0f}" y2="{h}" stroke="#fff" stroke-opacity=".06" stroke-width="{u*.3:.1f}"/>' for i in range(1, 8))
        + ''.join(f'<line x1="0" y1="{h*i/8:.0f}" x2="{w}" y2="{h*i/8:.0f}" stroke="#fff" stroke-opacity=".06" stroke-width="{u*.3:.1f}"/>' for i in range(1, 8))
        # DJ, booth and decks
        + f'<circle cx="{w*.5:.0f}" cy="{booth_y-u*30:.0f}" r="{u*7:.0f}" fill="#d9b99b"/>'
        f'<rect x="{w*.5-u*11:.0f}" y="{booth_y-u*23:.0f}" width="{u*22:.0f}" height="{u*26:.0f}" rx="{u*4:.0f}" fill="#15181d"/>'
        f'<rect x="{w*.5-u*38:.0f}" y="{booth_y:.0f}" width="{u*76:.0f}" height="{u*20:.0f}" rx="{u*2:.0f}" fill="#1d2127" stroke="#e6b774" stroke-width="{u*.6:.1f}"/>'
        f'<circle cx="{w*.5-u*22:.0f}" cy="{booth_y+u*7:.0f}" r="{u*6:.0f}" fill="#0e1013" stroke="#8dcccf" stroke-width="{u*.5:.1f}"/>'
        f'<circle cx="{w*.5+u*22:.0f}" cy="{booth_y+u*7:.0f}" r="{u*6:.0f}" fill="#0e1013" stroke="#8dcccf" stroke-width="{u*.5:.1f}"/>'
        f'{people}'
        f'<text x="{u*3:.0f}" y="{u*8:.0f}" font-family="sans-serif" font-size="{u*5:.0f}" fill="#fff" opacity=".9">{escape(Path(path).name)}</text>'
        f'<text x="{u*3:.0f}" y="{u*14:.0f}" font-family="monospace" font-size="{u*4:.0f}" fill="#fff" opacity=".7">{int(at//60):02}:{at % 60:05.2f} · {w}×{h} · demo frame</text>')


def svg(path, at, out_w, out_h, view, fit):
    w, h = media_info(path)['width'], media_info(path)['height']
    x, y, vw, vh = view
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{out_w}" height="{out_h}" viewBox="0 0 {out_w} {out_h}">'
            f'<rect width="{out_w}" height="{out_h}" fill="#000"/>'
            f'<svg width="{out_w}" height="{out_h}" viewBox="{x:.1f} {y:.1f} {vw:.1f} {vh:.1f}" '
            f'preserveAspectRatio="{"xMidYMid meet" if fit else "none"}">{scene(path, at, w, h)}</svg></svg>')


def framed_view(path, framing, mode):
    """Mirror multicam_edit.framing_filter: fit, or a fixed aspect crop with zoom."""
    info = media_info(path)
    iw, ih = info['width'], info['height']
    ow, oh = (2160, 3840) if mode == 'vertical' else (3840, 2160)
    if framing['mode'] == 'fit':
        return (0, 0, iw, ih), True
    cw = min(iw, ih*ow/oh)/framing['zoom']
    ch = cw*oh/ow
    cx, cy = framing['center']
    return (max(0, min(iw-cw, iw*cx-cw/2)), max(0, min(ih-ch, ih*cy-ch/2)), cw, ch), False


# ---------------------------------------------------------------- waveform

def waveform_data(path, bins=5000):
    duration = wav_info(path)
    peaks = None
    if duration:
        try:
            with wave.open(str(path), 'rb') as w:
                if w.getsampwidth() == 2:
                    data = array.array('h', w.readframes(w.getnframes()))
                    if sys.byteorder == 'big':
                        data.byteswap()
                    channels = w.getnchannels()
                    step = max(1, len(data)//channels//bins)*channels
                    stride = max(channels, step//64)  # sample ~64 points per bin: fast in pure Python
                    peaks = []
                    for start in range(0, len(data), step):
                        chunk = data[start:start+step:stride] or [0]
                        peaks.append(math.sqrt(sum(v*v for v in chunk)/len(chunk)))
        except (wave.Error, EOFError, OSError):
            peaks = None
    if not peaks:
        duration = duration or 180.0
        rng = random.Random(str(path))
        peaks = [(.3+.6*abs(math.sin(i/400)))*(.7+.3*rng.random()) for i in range(bins)]
    top = max(peaks) or 1
    peaks = [p/top for p in peaks]
    count = len(peaks)
    width = max(1, round(3/duration*count))
    smooth, total = [], 0.0
    for i, value in enumerate(peaks):  # moving average
        total += value
        if i >= width:
            total -= peaks[i-width]
        smooth.append(total/min(i+1, width))
    threshold = sorted(smooth)[int(len(smooth)*.75)]
    energetic, start = [], None
    for i, value in enumerate(smooth+[0]):
        if value >= threshold and start is None:
            start = i
        elif value < threshold and start is not None:
            a = max(0, start/count*duration-2); b = min(duration, i/count*duration+2)
            if b-a >= 4:
                score = sum(smooth[start:i])/max(1, i-start)
                energetic.append({'start': round(a, 3), 'end': round(min(b, a+45), 3), 'score': round(score, 3)})
            start = None
    distinct = []
    for item in sorted(energetic, key=lambda x: x['score'], reverse=True):
        if not any(item['start'] < c['end']+2 and item['end']+2 > c['start'] for c in distinct):
            distinct.append(item)
    return {'duration': duration, 'sample_rate': 8000, 'peaks': [round(p, 5) for p in peaks],
            'energetic': sorted(distinct[:20], key=lambda x: x['start'])}


# ---------------------------------------------------------------- edit plan

def plan(config, duration):
    """A seeded plan following the main-camera share, hold lengths and overrides."""
    fps = config['fps']; scale = config['cut_scale']
    rng = random.Random(config['seed'])
    cameras = config.get('cameras') or [{'id': 'A', 'label': 'A', 'clips': [{'path': p} for p in config['cam_a']]},
                                        {'id': 'B', 'label': 'B', 'clips': [{'path': p} for p in config['cam_b']]}]
    ids = [c['id'] for c in cameras]
    main = config['main_camera'] if config['main_camera'] in ids else ids[0]
    others = [i for i in ids if i != main] or [main]
    in_drop = lambda t: any(a <= t < b for a, b in config['drops'])
    in_break = lambda t: any(a <= t < b for a, b in config['breakdowns'])
    shots, t, previous, main_time = [], 0.0, None, 0.0
    while t < duration:
        if in_break(t):
            camera, hold, reason = main, config['breakdown_hold'], 'breakdown hold'
        elif in_drop(t):
            camera, hold, reason = rng.choice([i for i in ids if i != previous] or ids), config['drop_hold'], 'drop energy'
        elif previous != main and (t == 0 or main_time/t < config['main_share']):
            camera, hold, reason = main, config['main_hold'], 'main camera'
        else:
            camera, hold, reason = rng.choice([i for i in others if i != previous] or others), config['cutaway_hold'], 'cutaway'
        length = rng.uniform(*hold)*scale
        # Cut at the next drop or breakdown boundary, so sections get their own rhythm.
        boundary = min([x for pair in config['drops']+config['breakdowns'] for x in pair if x > t+1/fps] + [duration])
        end = min(boundary, round((t+length)*fps)/fps)
        if end <= t:
            end = duration
        shots.append({'start': t, 'end': end, 'camera': camera, 'reason': reason, 'source': None})
        main_time += (end-t)*(camera == main)
        t, previous = end, camera
    for override in sorted(config['shot_overrides'], key=lambda o: o['start']):
        a, b = override['start'], min(duration, override['end'])
        kept = []
        for s in shots:
            if s['end'] <= a or s['start'] >= b:
                kept.append(s); continue
            if s['start'] < a: kept.append({**s, 'end': a})
            if s['end'] > b: kept.append({**s, 'start': b})
        kept.append({'start': a, 'end': b, 'camera': override['camera_id'], 'reason': 'manual override',
                     'source': override.get('source_path')})
        shots = sorted(kept, key=lambda s: s['start'])
    return cameras, main, shots


def build_report(config, job_dir):
    duration = wav_info(config['audio']) or 180.0
    cameras, main, shots = plan(config, duration)
    offsets = {}
    sync = []
    for camera in cameras:
        for index, clip in enumerate(camera['clips']):
            info = media_info(clip['path'])
            seed = int(hashlib.sha256(clip['path'].encode()).hexdigest()[:6], 16)
            offset = -((seed % 900)/100) + index*info['duration']
            offsets[clip['path']] = offset
            manual = next((o for o in config['overrides'] if o['path'] == clip['path']), None)
            drift = manual['drift_ppm'] if manual and manual['drift_ppm'] is not None else ((seed % 41)-20)/2
            if manual and manual['offset'] is not None:
                offset = offsets[clip['path']] = manual['offset']
            sync.append({'angle': camera['id'], 'source_path': clip['path'], 'filename': Path(clip['path']).name,
                         'label': camera.get('label') or camera['id'], 'framing': clip.get('framing'),
                         'offset_seconds': offset, 'rate': 1+drift/1e6, 'drift_ppm': drift,
                         'coverage_start_seconds': max(0, offset), 'coverage_end_seconds': min(duration, offset+info['duration']),
                         'source_duration_seconds': info['duration'], 'method': 'manual' if manual else 'correlation',
                         'matched_anchors': 7})
    first_clip = {c['id']: c['clips'][0]['path'] for c in cameras}
    rows, seconds = [], {}
    for n, s in enumerate(shots, 1):
        source = s['source'] or first_clip[s['camera']]
        source_in = max(0, s['start']-offsets.get(source, 0))
        rows.append({'index': n, 'start_seconds': s['start'], 'end_seconds': s['end'], 'angle': s['camera'],
                     'source_path': source, 'source_in_seconds': source_in,
                     'source_out_seconds': source_in+s['end']-s['start'], 'reason': s['reason']})
        seconds[s['camera']] = seconds.get(s['camera'], 0)+s['end']-s['start']
    shares = {c['id']: seconds.get(c['id'], 0)/duration for c in cameras}
    width, height = (2160, 3840) if config['mode'] == 'vertical' else (3840, 2160)
    suffix = '_vertical' if config['mode'] == 'vertical' else ''
    name = config['output_name'] or f'multicam_cut{suffix}'
    previews = []
    for camera in cameras:
        for index, clip in enumerate(camera['clips']):
            view, fit = framed_view(clip['path'], clip.get('framing') or {'mode': 'fit'}, config['mode'])
            pw, ph = (540, 960) if config['mode'] == 'vertical' else (960, 540)
            target = job_dir/f'{camera["id"]}_{index+1}_{Path(clip["path"]).stem}{suffix}_crop_preview.svg'
            target.write_text(svg(clip['path'], 3, pw, ph, view, fit), encoding='utf-8')
            previews.append({'angle': camera['id'], 'source_path': clip['path'], 'path': str(target)})
    cut_list = job_dir/f'cut_list{suffix}.txt'
    cut_list.write_text('DEMO PLAN (no video rendered)\n' + ''.join(
        f'{r["index"]:04} | {r["start_seconds"]:9.3f} -> {r["end_seconds"]:9.3f} | CAM_{r["angle"]} | {r["source_path"]} | {r["reason"]}\n'
        for r in rows), encoding='utf-8')
    return {
        'schema_version': 1, 'status': 'planned', 'demo': True,
        'updated_at': dt.datetime.now(dt.timezone.utc).isoformat(), 'settings': config,
        'duration_seconds': duration, 'shot_overrides': config['shot_overrides'],
        'fps': config['fps'], 'width': width, 'height': height, 'audio': config['audio'],
        'sections': {'drops': config['drops'], 'breakdowns': config['breakdowns'], 'activities': config['activities']},
        'sync': sync, 'shots': rows,
        'stats': {'a_share': shares.get('A', 0), 'b_share': shares.get('B', 0), 'main_share': shares.get(main, 0),
                  'camera_shares': shares, 'average_cut_seconds': duration/max(1, len(rows)),
                  'black_seconds': 0.0, 'shot_count': len(rows), 'cut_count': max(0, len(rows)-1)},
        'outputs': {'video': None, 'planned_video': str(Path(config['output_dir'])/f'{name}.mp4'),
                    'cut_list': str(cut_list), 'report': str(job_dir/'report.json'), 'previews': previews},
    }


# ---------------------------------------------------------------- server overrides

class DemoStudio(server.Studio):
    def dependencies(self):
        return {'ffmpeg': True, 'ffprobe': True, 'numpy': True, 'scipy': True}

    def worker(self, job):
        directory = Path(job['directory'])
        def log(line, **update):
            with self.lock:
                if job['cancel_requested']:
                    raise KeyboardInterrupt
                job['logs'].append(line); job.update(update)
            time.sleep(.35)
        try:
            with self.lock:
                job.update(status='running', stage='Synchronising' if job.get('kind', 'edit') == 'edit' else 'Processing clip')
            c = job['config']
            if job.get('kind', 'edit') == 'edit':
                log(f'Main camera: {c["main_camera"]}; target screen time: {c["main_share"]:.0%}; mode: {c["mode"]}')
                log('Preparing audio bounce for correlation …')
                for clip in [clip['path'] for cam in c.get('cameras', []) for clip in cam['clips']] + c.get('cam_a', []) + c.get('cam_b', []):
                    log(f'Syncing {Path(clip).name} at 8000 Hz …', stage=f'Syncing {Path(clip).name}')
                    log('  audio    12.000s -> bounce    21.480s; correlation 0.612 (demo)')
                report = build_report(c, directory)
                (directory/'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
                log('Fixed crop previews ready (demo SVG frames).', stage='Preparing crop previews')
                if c['plan_only']:
                    log(f'Plan saved: {report["outputs"]["cut_list"]}')
                    with self.lock:
                        job.update(status='completed', stage='Plan ready', progress=100)
                    return
                total = len(report['shots'])
                for n in range(1, min(total, 3)+1):
                    log(f'Rendering {n}/{total}: (demo)', stage=f'Rendering shot {n} of {total}', progress=round((n-1)/total*95, 1))
            else:
                log('Exporting selected clip...' if job['kind'] == 'clip' else 'Processing effects...')
                for step in (10, 25, 40):
                    log(f'progress (demo) {step}%', progress=step)
            with self.lock:
                job['logs'].append('ERROR: '+STOP_MESSAGE)
                job.update(status='failed', stage='Demo stops before export', error=STOP_MESSAGE, progress=None)
        except KeyboardInterrupt:
            with self.lock:
                job.update(status='cancelled', stage='Cancelled', progress=None)
        except Exception as exc:
            with self.lock:
                job.update(status='failed', stage='Needs attention', error=str(exc), progress=None)
                job['logs'].append(str(exc))
        finally:
            with self.lock:
                job['process'] = None; job['finished_at'] = dt.datetime.now().isoformat(); self.save(job)
                if self.active == job['id']: self.active = None


class DemoHandler(server.Handler):
    def bytes_response(self, body, mime):
        if mime.startswith('text/html'):
            body = body.replace(b'LOCAL WORKSPACE', DEMO_BADGE.encode())
        return super().bytes_response(body, mime)

    def do_POST(self):
        if self.path.split('?')[0] != '/api/probe':
            return super().do_POST()
        if not self.allowed():
            return
        try:
            data = self.read_json()
            paths = data.get('paths', []) if isinstance(data, dict) else None
            if not isinstance(paths, list) or len(paths) > 200:
                raise ValueError('Too many files.')
            files = []
            for value in paths:
                p = server.resolved(value)
                item = {'path': str(p), 'name': p.name}
                if not p.is_file() or p.suffix.lower() not in server.VIDEO_EXTS | server.AUDIO_EXTS:
                    item['error'] = 'Choose a MOV, MP4 or WAV file.'
                else:
                    item.update(media_info(p))
                files.append(item)
            self.json_response(200, {'files': files})
        except (OSError, ValueError, KeyError, TypeError) as exc:
            self.error_response(400, exc)

    def image(self, body, width=None, height=None):
        folder = self.studio.state/'previews'; folder.mkdir(exist_ok=True)
        target = folder/(secrets.token_hex(12)+'.svg')
        target.write_text(body, encoding='utf-8')
        item = self.studio.register(target, 'image')
        if width:
            item.update(width=width, height=height)
        return self.json_response(200, item)

    def preview(self, data):
        p = server.resolved(data.get('path'))
        if not p.is_file() or p.suffix.lower() not in server.VIDEO_EXTS:
            raise ValueError('Choose a camera recording first.')
        mode = data.get('mode', 'horizontal')
        if mode not in ('horizontal', 'vertical'):
            raise ValueError('Invalid preview mode.')
        at = server.finite(data.get('time', 3), 'Preview time', 0)
        framing = server.validate_framing(data['framing']) if data.get('framing') is not None else {'mode': 'fit'}
        view, fit = framed_view(p, framing, mode)
        pw, ph = (540, 960) if mode == 'vertical' else (960, 540)
        return self.image(svg(p, at, pw, ph, view, fit))

    def source_frame(self, data):
        p = server.resolved(data.get('path'))
        if not p.is_file() or p.suffix.lower() not in server.VIDEO_EXTS:
            raise ValueError('Choose a camera recording.')
        at = server.finite(data.get('time', 3), 'Preview time', 0)
        info = media_info(p)
        factor = min(1, 1280/max(info['width'], info['height']))
        w, h = round(info['width']*factor), round(info['height']*factor)
        return self.image(svg(p, at, w, h, (0, 0, info['width'], info['height']), True), w, h)

    def waveform(self, data):
        p = server.resolved(data.get('path'))
        if not p.is_file() or p.suffix.lower() not in server.VIDEO_EXTS | server.AUDIO_EXTS:
            raise ValueError('Choose a WAV bounce or rendered video.')
        # Placeholder movies have no audio; use the sample bounce so playback still works.
        audio = p if p.suffix.lower() == '.wav' else self.studio.default_folder/BOUNCE
        if not audio.is_file():
            audio = p
        result = waveform_data(audio)
        result['audio_url'] = self.studio.register(audio, 'audio')['url']
        return self.json_response(200, result)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, default=8766)
    parser.add_argument('--open', action='store_true')
    parser.add_argument('--state-dir', type=Path, default=server.APP/'.multicam-demo')
    args = parser.parse_args()
    state = args.state_dir.expanduser().resolve()
    media = state/'Sample project'
    prepare_media(media)
    import effects
    effects.probe = ffprobe_json
    server.Studio = DemoStudio
    server.Handler = DemoHandler
    sys.argv = ['server.py', '--port', str(args.port), '--state-dir', str(state),
                '--default-folder', str(media), '--default-output', str(media/'Exports'),
                '--root', str(media), '--root', str(Path.home())] + (['--open'] if args.open else [])
    print('Multicam Studio UI demo: previews and plans are simulated; nothing is rendered.', flush=True)
    server.main()


if __name__ == '__main__':
    main()
