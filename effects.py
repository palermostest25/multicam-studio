#!/usr/bin/env python3
"""Export a clip or add effects to a finished Multicam movie, using FFmpeg.

    python3 effects.py --config settings.json --report-json report.json

Only the Python standard library is needed. Processing preserves source dimensions,
frame rate, and audio channel count. Previews render the selection's first five
seconds; an end fade outside that interval will not appear in the preview.
"""
from __future__ import annotations

import argparse
from fractions import Fraction
import json
import math
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

PRESETS = {'ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow'}
STYLES = {'none', 'warm', 'cool', 'mono', 'vintage', 'vivid'}


def numeric(value, label, minimum=None, maximum=None, integer=False):
    if isinstance(value, bool):
        raise ValueError(f'{label} must be a number.')
    try:
        value = float(value)
    except (ValueError, TypeError):
        raise ValueError(f'{label} must be a number.')
    if not math.isfinite(value):
        raise ValueError(f'{label} must be a finite number.')
    if minimum is not None and value < minimum or maximum is not None and value > maximum:
        raise ValueError(f'{label} is outside its allowed range.')
    if integer and value != int(value):
        raise ValueError(f'{label} must be a whole number.')
    return int(value) if integer else value


def path_value(value, label):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f'Choose {label}.')
    return Path(value).expanduser().resolve()


def probe(path):
    try:
        p = subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-show_format',
                            '-of', 'json', str(path)], capture_output=True, text=True, timeout=30,
                           encoding='utf-8', errors='replace')
    except FileNotFoundError:
        raise ValueError('FFprobe is missing. Install FFmpeg first (macOS: brew install ffmpeg; Windows: winget install Gyan.FFmpeg)')
    if p.returncode:
        raise ValueError('Cannot read the source movie: ' + p.stderr[-1500:])
    try:
        return json.loads(p.stdout)
    except ValueError:
        raise ValueError('FFprobe did not return valid movie information.')


def stream_duration(info, stream):
    value = stream.get('duration')
    if value in (None, 'N/A'):
        value = info.get('format', {}).get('duration', 0)
    return numeric(value, 'Movie duration', 0)


def same_file(first, second):
    if first.resolve() == second.resolve():
        return True
    try:
        return first.samefile(second)
    except (FileNotFoundError, OSError):
        return False


def has_effects(c):
    return any((c['fade_in'], c['fade_out'], c['bounce'], c['vignette'],
                c['style'] != 'none', c['brightness'] != 0,
                c['contrast'] != 1, c['saturation'] != 1))


def validate_config(raw, *, metadata=None):
    if not isinstance(raw, dict):
        raise ValueError('Expected clip/effect settings.')
    source = path_value(raw.get('source_path'), 'a source movie')
    if not source.is_file() or source.suffix.lower() not in {'.mp4', '.mov'}:
        raise ValueError('Choose a readable MP4 or MOV source movie.')
    output_dir = path_value(raw.get('output_dir'), 'an output folder')
    if output_dir.exists() and not output_dir.is_dir():
        raise ValueError('Output location must be a folder.')
    c = {'source_path': str(source), 'output_dir': str(output_dir)}
    for key, default in [('overwrite', False), ('vignette', False), ('preview', False)]:
        value = raw.get(key, default)
        if not isinstance(value, bool):
            raise ValueError(f'{key} must be on or off.')
        c[key] = value
    for key, default, lo, hi, integer in [
        ('start', 0, 0, None, False), ('crf', 18, 0, 51, True),
        ('fade_in', 0, 0, None, False), ('fade_out', 0, 0, None, False),
        ('bounce', 0, 0, 1, False), ('brightness', 0, -.3, .3, False),
        ('contrast', 1, .5, 2, False), ('saturation', 1, 0, 2, False)]:
        c[key] = numeric(raw.get(key, default), key, lo, hi, integer)
    for key, default, choices in [('preset', 'medium', PRESETS), ('style', 'none', STYLES)]:
        c[key] = raw.get(key, default)
        if not isinstance(c[key], str) or c[key] not in choices:
            raise ValueError(f'Invalid {key}.')
    meta = probe(source) if metadata is None else metadata
    video = next((s for s in meta.get('streams', []) if s.get('codec_type') == 'video'), None)
    audio = next((s for s in meta.get('streams', []) if s.get('codec_type') == 'audio'), None)
    if video is None:
        raise ValueError('The source has no video track.')
    width, height = int(video.get('width', 0)), int(video.get('height', 0))
    rotation = next((s.get('rotation', 0) for s in video.get('side_data_list', [])
                     if 'rotation' in s), video.get('tags', {}).get('rotate', 0))
    if abs(round(float(rotation))) % 180 == 90:
        width, height = height, width
    if width <= 0 or height <= 0 or width % 2 or height % 2:
        raise ValueError('Source dimensions must be positive and even for H.264 output.')
    try:
        fps = Fraction(video.get('avg_frame_rate') or video.get('r_frame_rate') or '0/1')
        if fps <= 0:
            fps = Fraction(video.get('r_frame_rate', '0/1'))
        if fps <= 0 or fps > 240:
            raise ValueError
    except (ValueError, ZeroDivisionError):
        raise ValueError('Cannot determine a supported source frame rate.')
    duration = stream_duration(meta, video)
    if duration <= 0:
        raise ValueError('Source movie has no positive duration.')
    end = duration if raw.get('end') is None else numeric(raw['end'], 'End time', 0)
    if end > duration + max(0.001, .5 / float(fps)):
        raise ValueError(f'End time exceeds the movie duration ({duration:.3f} seconds).')
    end = min(end, duration)
    if c['start'] >= end:
        raise ValueError('End time must be after start time and within the source movie.')
    selected_duration = end - c['start']
    if selected_duration + 1e-8 < 1 / float(fps):
        raise ValueError('The selection must contain at least one video frame.')
    if c['fade_in'] + c['fade_out'] > selected_duration + 1e-8:
        raise ValueError('Fade-in and fade-out durations together cannot exceed the selection length.')
    c.update(end=end, selection_duration=selected_duration,
             render_duration=min(5, selected_duration) if c['preview'] else selected_duration,
             source_duration=duration, width=width, height=height,
             fps=float(fps), fps_expression=str(fps), has_audio=audio is not None,
             audio_channels=int(audio.get('channels', 0)) if audio else 0)
    name = raw.get('output_name') or ''
    if not isinstance(name, str):
        raise ValueError('Output name must be a filename.')
    name = name.strip()
    if name.lower().endswith('.mp4'):
        name = name[:-4]
    if not name:
        name = 'multicam_effects' if has_effects(c) else 'multicam_clip'
    if c['preview'] and not name.lower().endswith('_preview'):
        name += '_preview'
    if name in ('.', '..') or any(ch in name for ch in '/\\\x00\r\n') or len(name) > 180:
        raise ValueError('Output name must be a filename without a folder path.')
    c['output_name'] = name + '.mp4'
    output = output_dir / c['output_name']
    if same_file(source, output):
        raise ValueError('Output must be different from the source movie, including links to it.')
    if output.exists() and not output.is_file():
        raise ValueError('The output filename points to a folder. Choose another name.')
    if output.exists() and not c['overwrite']:
        raise ValueError('The output already exists. Enable overwrite or choose another name.')
    c['output_path'] = str(output)
    return c


def video_filters(c):
    filters = ['setpts=PTS-STARTPTS', f'fps={c["fps_expression"]}:start_time=0']
    if c['bounce']:
        # Up to 3% movement in each direction at full strength; the enlarged image
        # always covers the crop. Original playback speed and duration are retained.
        w, h = c['width'], c['height']
        sw = w + 2 * math.floor(w * .03 * c['bounce'])
        sh = h + 2 * math.floor(h * .03 * c['bounce'])
        filters += [f'scale={sw}:{sh}',
                    f"crop={w}:{h}:x='(in_w-out_w)/2*(1+sin(2*PI*t*1.4))':"
                    "y='(in_h-out_h)/2*(1+sin(2*PI*t*1.9+0.8))'"]
    styles = {
        'none': [],
        'warm': ['colorbalance=rs=0.035:rm=0.04:bs=-0.035:bm=-0.025'],
        'cool': ['colorbalance=rs=-0.025:rm=-0.02:bs=0.045:bm=0.035'],
        'mono': ['hue=s=0'],
        'vintage': ['eq=contrast=0.94:saturation=0.7:brightness=0.025',
                    'colorbalance=rm=0.04:bm=-0.03'],
        'vivid': ['eq=contrast=1.08:saturation=1.22'],
    }
    filters += styles[c['style']]
    if c['brightness'] or c['contrast'] != 1 or c['saturation'] != 1:
        filters.append(f'eq=brightness={c["brightness"]}:contrast={c["contrast"]}:saturation={c["saturation"]}')
    if c['vignette']:
        filters.append('vignette=PI/5')
    if c['fade_in']:
        filters.append(f'fade=t=in:st=0:d={c["fade_in"]}')
    if c['fade_out']:
        filters.append(f'fade=t=out:st={c["selection_duration"]-c["fade_out"]:.9f}:d={c["fade_out"]}')
    filters += ['setsar=1', 'format=yuv420p']
    return ','.join(filters)


def audio_filters(c):
    filters = ['asetpts=PTS-STARTPTS', f'atrim=duration={c["render_duration"]:.9f}']
    if c['fade_in']:
        filters.append(f'afade=t=in:st=0:d={c["fade_in"]}')
    if c['fade_out']:
        filters.append(f'afade=t=out:st={c["selection_duration"]-c["fade_out"]:.9f}:d={c["fade_out"]}')
    return ','.join(filters)


def render(raw, report_path=None, *, progress_offset=0, total_duration=None):
    c = validate_config(raw)
    for binary in ('ffmpeg', 'ffprobe'):
        if not shutil.which(binary):
            raise ValueError(f'Missing {binary}. Install FFmpeg (macOS: brew install ffmpeg; Windows: winget install Gyan.FFmpeg)')
    source, output = Path(c['source_path']), Path(c['output_path'])
    report = Path(report_path).expanduser().resolve() if report_path else output.with_suffix('.json')
    if same_file(report, source) or same_file(report, output):
        raise ValueError('The report path must differ from both source and output movie.')
    if report.exists() and not c['overwrite']:
        raise ValueError('The report already exists. Enable overwrite or choose another report path.')
    output.parent.mkdir(parents=True, exist_ok=True)
    report.parent.mkdir(parents=True, exist_ok=True)
    print('Processing effects...' if has_effects(c) else 'Exporting selected clip...', flush=True)
    print(f'duration_seconds={total_duration or c["render_duration"]:.6f}', flush=True)
    if c['preview']:
        print('Preview: first five seconds at most; the selection end fade may be outside this preview.', flush=True)
    with tempfile.TemporaryDirectory(prefix='.multicam_effects_', dir=output.parent) as tmp:
        encoded = Path(tmp) / 'processed.mp4'
        errors = Path(tmp) / 'ffmpeg.log'
        cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-y']
        # Seeking to zero can discard AAC priming twice on some FFmpeg builds.
        # Normal decoding at zero preserves the first decoded audio frame.
        if c['start'] > 0:
            cmd += ['-ss', f'{c["start"]:.9f}']
        cmd += ['-i', str(source),
               '-map', '0:v:0', '-vf', video_filters(c), '-c:v', 'libx264',
               '-preset', c['preset'], '-crf', str(c['crf']), '-pix_fmt', 'yuv420p']
        if c['has_audio']:
            cmd += ['-map', '0:a:0', '-af', audio_filters(c), '-c:a', 'aac', '-b:a', '320k']
        else:
            cmd += ['-an']
        cmd += ['-sn', '-dn', '-map_metadata', '-1', '-metadata:s:v:0', 'rotate=0',
                '-t', f'{c["render_duration"]:.9f}', '-movflags', '+faststart',
                '-progress', 'pipe:1', '-nostats', str(encoded)]
        proc = None
        try:
            with errors.open('w', encoding='utf-8') as log:
                # Inherit the worker's process group so Studio cancels FFmpeg too.
                proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=log, text=True,
                                        encoding='utf-8', errors='replace')
                for line in proc.stdout:
                    if line.startswith('out_time_us='):
                        value = line.partition('=')[2].strip()
                        try:
                            elapsed = max(0, min(c['render_duration'], float(value) / 1e6))
                        except ValueError:
                            continue
                        print(f'progress_seconds={progress_offset + elapsed:.6f}', flush=True)
                code = proc.wait()
            if code:
                raise RuntimeError('FFmpeg failed:\n' + errors.read_text(encoding='utf-8', errors='replace')[-6000:])
        finally:
            if proc is not None and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            if proc is not None and proc.stdout is not None:
                proc.stdout.close()
        info = probe(encoded)
        videos = [s for s in info['streams'] if s.get('codec_type') == 'video']
        audios = [s for s in info['streams'] if s.get('codec_type') == 'audio']
        if (len(videos) != 1 or videos[0].get('codec_name') != 'h264'
                or videos[0].get('width') != c['width'] or videos[0].get('height') != c['height']
                or abs(stream_duration(info, videos[0]) - c['render_duration']) > 1 / c['fps'] + .01
                or len(audios) != int(c['has_audio'])):
            raise RuntimeError('Processed movie failed stream/duration verification.')
        if c['has_audio'] and (audios[0].get('channels') != c['audio_channels']
                or abs(stream_duration(info, audios[0]) - c['render_duration']) > .06):
            raise RuntimeError('Processed movie failed audio verification.')
        if abs(float(Fraction(videos[0]['avg_frame_rate'])) - c['fps']) > .001:
            raise RuntimeError('Processed movie did not preserve the source frame rate.')
        # Recheck in case another job or application changed the destination.
        if same_file(source, output) or same_file(source, report) or same_file(output, report):
            raise ValueError('An output path now points to an input or another output.')
        if not c['overwrite'] and (output.exists() or report.exists()):
            raise ValueError('An output appeared during rendering. Choose another name or enable overwrite.')
        encoded.replace(output)
        result = {'type': 'effects' if has_effects(c) else 'clip', 'status': 'rendered',
                  'preview': c['preview'], 'duration_seconds': c['render_duration'],
                  'width': c['width'], 'height': c['height'], 'fps': c['fps'],
                  'source_path': str(source), 'start_seconds': c['start'],
                  'end_seconds': c['start'] + c['render_duration'],
                  'selection_end_seconds': c['end'], 'settings': c,
                  'outputs': {'video': str(output), 'report': str(report)}}
        # Report may live on a different disk: stage it beside its final location.
        with tempfile.NamedTemporaryFile('w', prefix='.effects-report-', suffix='.json',
                                         dir=report.parent, delete=False, encoding='utf-8') as handle:
            report_tmp = Path(handle.name)
            json.dump(result, handle, indent=2)
            handle.write('\n')
        try:
            report_tmp.replace(report)
        finally:
            report_tmp.unlink(missing_ok=True)
    print(f'progress_seconds={progress_offset + c["render_duration"]:.6f}', flush=True)
    print(f'Done: {output}\nReport: {report}', flush=True)
    return result



def validate_batch(raw):
    """Preflight every destination before any clip is written."""
    if not isinstance(raw, dict):
        raise ValueError('Expected batch highlight settings.')
    ranges = raw.get('clips')
    if not isinstance(ranges, list) or not 1 <= len(ranges) <= 1000:
        raise ValueError('Select between 1 and 1,000 highlights for a batch.')
    prefix = raw.get('output_name') or 'multicam_highlight'
    if not isinstance(prefix, str):
        raise ValueError('Output name must be a filename.')
    prefix = prefix.strip()
    if prefix.lower().endswith('.mp4'):
        prefix = prefix[:-4]
    if not prefix or prefix in ('.', '..') or any(c in prefix for c in '/\\\x00\r\n') or len(prefix) > 120:
        raise ValueError('Batch filename must be 1–120 characters without a folder path.')
    source = path_value(raw.get('source_path'), 'a source movie')
    metadata = probe(source)
    settings = {k: raw[k] for k in ('source_path', 'output_dir', 'overwrite', 'crf', 'preset') if k in raw}
    clips = []
    previous_end = 0
    for index, item in enumerate(ranges, 1):
        if not isinstance(item, dict):
            raise ValueError('Every highlight needs a start and end time.')
        start = numeric(item.get('start'), 'Highlight start', 0)
        end = numeric(item.get('end'), 'Highlight end', 0)
        if start < previous_end - .000001:
            raise ValueError('Highlights must be in time order without overlaps.')
        previous_end = end
        milliseconds = round(start * 1000)
        seconds, millis = divmod(milliseconds, 1000)
        minutes, seconds = divmod(seconds, 60)
        hours, minutes = divmod(minutes, 60)
        name = f'{prefix}_{index:03d}_{hours:02d}-{minutes:02d}-{seconds:02d}-{millis:03d}.mp4'
        clips.append(validate_config({**settings, 'start': start, 'end': end, 'output_name': name}, metadata=metadata))
    first = clips[0]
    manifest = Path(first['output_dir']) / (prefix + '_highlights.json')
    if same_file(source, manifest) or any(same_file(Path(c['output_path']), manifest) for c in clips):
        raise ValueError('The batch manifest must be separate from the movie files.')
    if manifest.exists() and (not first['overwrite'] or not manifest.is_file()):
        raise ValueError('The batch manifest already exists. Choose another filename or enable overwrite.')
    return {**settings, 'source_path': str(source), 'output_dir': first['output_dir'],
            'output_name': prefix, 'overwrite': first['overwrite'], 'batch': True,
            'clips': [{'start': c['start'], 'end': c['end']} for c in clips],
            'clip_configs': clips, 'manifest_path': str(manifest),
            'render_duration': sum(c['render_duration'] for c in clips)}


def write_json_atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile('w', prefix='.highlight-report-', suffix='.json',
                                     dir=path.parent, delete=False, encoding='utf-8') as handle:
        temporary = Path(handle.name)
        json.dump(value, handle, indent=2)
        handle.write('\n')
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def render_batch(raw, report_path=None):
    c = validate_batch(raw)
    manifest = Path(c['manifest_path'])
    report = Path(report_path).expanduser().resolve() if report_path else manifest
    if same_file(report, Path(c['source_path'])) or any(same_file(report, Path(x['output_path'])) for x in c['clip_configs']):
        raise ValueError('The batch report must be separate from the movie files.')
    if report != manifest and report.exists() and not c['overwrite']:
        raise ValueError('The batch report already exists. Choose another name or enable overwrite.')
    result = {'type': 'highlights', 'status': 'rendering', 'source_path': c['source_path'],
              'clip_count': len(c['clips']), 'completed_count': 0,
              'duration_seconds': c['render_duration'], 'clips': [],
              'outputs': {'videos': [], 'report': str(manifest)}}
    def save():
        write_json_atomic(manifest, result)
        if report != manifest:
            write_json_atomic(report, result)
    save()
    progress = 0
    try:
        with tempfile.TemporaryDirectory(prefix='.multicam-batch-', dir=c['output_dir']) as folder:
            for index, clip in enumerate(c['clip_configs'], 1):
                print(f'Batch clip {index}/{len(c["clips"])}', flush=True)
                rendered = render(clip, Path(folder) / f'{index}.json',
                                  progress_offset=progress, total_duration=c['render_duration'])
                progress += rendered['duration_seconds']
                result['outputs']['videos'].append({'path': rendered['outputs']['video'],
                    'start': clip['start'], 'end': clip['end']})
                result['clips'].append({'index': index, 'start': clip['start'], 'end': clip['end'],
                                        'path': rendered['outputs']['video']})
                result['completed_count'] = index
                save()
        result['status'] = 'rendered'
    except BaseException as exc:
        result['status'] = 'cancelled' if isinstance(exc, KeyboardInterrupt) else 'failed'
        result['error'] = 'Cancelled. Completed clips have been kept.' if isinstance(exc, KeyboardInterrupt) else str(exc)
        raise
    finally:
        save()
    print(f'Done: {result["completed_count"]} highlights. Manifest: {manifest}', flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--config', required=True, type=Path, help='JSON clip/effects settings')
    parser.add_argument('--report-json', type=Path, help='Optional output report path')
    args = parser.parse_args()
    # Windows cancels with Ctrl+Break; handle it like Ctrl+C so scratch files are removed.
    if hasattr(signal, 'SIGBREAK'):
        signal.signal(signal.SIGBREAK, signal.default_int_handler)
    raw = json.loads(args.config.read_text(encoding='utf-8'))
    (render_batch if raw.get('batch') else render)(raw, args.report_json)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit('\nCancelled; temporary effects files removed.')
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
        sys.exit(f'ERROR: {exc}')
