#!/usr/bin/env python3
"""Export independent audio excerpts against shared long camera recordings.

    python3 audio_batch.py --config multicam-setup.json

Each audio part has its own zero-based timing, synchronization and output folder.
Camera audio is decoded once per batch. Gaps between excerpts are not joined.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import re
import signal
import sys
import tempfile

EXPORT_FOLDERS = ('Full sets', 'Social media', 'Social media alternatives', 'Project files')


def readable_name(text, fallback='Set'):
    """Same rule as multicam_edit.readable_name (kept here so validation stays light)."""
    name = re.sub(r'\s+', ' ', re.sub(r'[^A-Za-z0-9 ._-]+', ' ', str(text))).strip(' .')[:100].rstrip(' .')
    return name if name and name[0].isalnum() else fallback


TIMING_KEYS = ('overrides', 'shot_overrides', 'drops', 'breakdowns', 'activities', 'clip_excludes')


def validate_config(raw):
    from server import validate_config as validate_edit
    if not isinstance(raw, dict):
        raise ValueError('Expected an edit project.')
    parts = raw.get('audio_parts')
    if not isinstance(parts, list) or not 1 <= len(parts) <= 100:
        raise ValueError('Choose between 1 and 100 WAV audio excerpts.')
    base = {k: v for k, v in raw.items() if k != 'audio_parts'}
    checked, seen = [], set()
    for item in parts:
        if not isinstance(item, dict):
            raise ValueError('Each audio excerpt needs a path and its timing settings.')
        settings = {key: item.get(key, []) for key in TIMING_KEYS}
        part = validate_edit({**base, **settings, 'audio': item.get('path')})
        if any(part[key][0]*part['cut_scale'] < 1/part['fps'] for key in ('main_hold','cutaway_hold','drop_hold','breakdown_hold')):
            raise ValueError('Each scaled hold length must contain at least one output frame.')
        path = part['audio']
        if path in seen:
            raise ValueError('The same audio excerpt is selected more than once.')
        seen.add(path)
        checked.append(part)
    first = checked[0]
    prefix = first['output_name']
    inputs = [Path(p['audio']) for p in checked]
    if first.get('cameras'):
        inputs.extend(Path(c['path']) for cam in first['cameras'] for c in cam['clips'])
    else:
        inputs.extend(Path(p) for key in ('cam_a', 'cam_b') for p in first[key])
    # Every excerpt writes into the same export root (Full sets, Social media, Social media
    # alternatives, Project files), each under its own set name.
    root = Path(first['output_dir']).expanduser().resolve()
    for folder in EXPORT_FOLDERS:
        if any(p.is_relative_to(root / folder) for p in inputs):
            raise ValueError(f'The {folder} folder contains an input. Choose a different output folder.')
    used = set()
    for index, part in enumerate(checked, 1):
        if prefix:
            name = f'{prefix[:90]} - Part {index}'
        else:
            name = readable_name(Path(part['audio']).stem) + (' vertical' if part['mode'] == 'vertical' else '')
        if name.casefold() in used:
            name = f'{name} ({index})'
        used.add(name.casefold())
        extension = 'mov' if part.get('codec') == 'prores' or part.get('container') == 'mov' else 'mp4'
        files = root / 'Project files' / name
        if not part['overwrite'] and ((root / 'Full sets' / f'{name}.{extension}').exists()
                                      or (files.is_dir() and any(files.iterdir()))):
            raise ValueError(f'Excerpt output already exists: {files}. Enable overwrite or choose another folder.')
        part.update(output_dir=str(root), output_name=name)
    return {**first, 'audio': first['audio'], 'output_dir': str(Path(base['output_dir']).expanduser().resolve()),
            'output_name': prefix or 'Audio parts', 'audio_parts': [dict(path=p['audio'], **{key: p[key] for key in TIMING_KEYS}) for p in checked],
            'part_configs': checked}


def run_batch(raw, report_path=None):
    import multicam_edit as engine
    from effects import write_json_atomic
    from server import command_for, worker_command
    config = validate_config(raw)
    folder = Path(config['output_dir'])
    folder.mkdir(parents=True, exist_ok=True)
    (folder / 'Project files').mkdir(parents=True, exist_ok=True)
    manifest = folder / 'Project files' / (config['output_name'] + ' - audio parts.json')
    report = Path(report_path).expanduser().resolve() if report_path else manifest
    all_inputs = {Path(p['audio']) for p in config['part_configs']}
    definitions = config.get('cameras') or [dict(id=id, clips=[dict(path=p, framing={'mode': 'crop', 'center': config[key], 'zoom': 1}) for p in config[paths]]) for id, paths, key in [('A', 'cam_a', 'a_center'), ('B', 'cam_b', 'b_center')]]
    all_inputs.update(Path(clip['path']) for camera in definitions for clip in camera['clips'])
    for target in (manifest, report):
        if target in all_inputs or (target.exists() and any(target.samefile(p) for p in all_inputs)):
            raise ValueError('A batch report would overwrite an input file.')
        if target.exists() and (not target.is_file() or not config['overwrite']):
            raise ValueError(f'Batch report already exists: {target}. Enable overwrite or choose another name.')
    result = {'type': 'audio_batch', 'status': 'planning' if config['plan_only'] else 'rendering',
              'part_count': len(config['part_configs']), 'completed_count': 0, 'parts': [],
              'outputs': {'videos': [], 'report': str(manifest)}}
    def save():
        write_json_atomic(manifest, result)
        if report != manifest:
            write_json_atomic(report, result)
    save()
    try:
        with tempfile.TemporaryDirectory(prefix='.multicam_audio_batch_', dir=folder,
                                         ignore_cleanup_errors=True) as temp:
            work = Path(temp)
            samples = {}
            cameras = {(cam['id'], clip['path']): engine.read_camera(Path(clip['path']), cam['id']) for cam in definitions for clip in cam['clips']}
            for index, original in enumerate(config['part_configs'], 1):
                print(f'Audio excerpt {index}/{len(config["part_configs"])}: {Path(original["audio"]).name}', flush=True)
                entry = {'index': index, 'audio': original['audio'], 'status': 'synchronising', 'warnings': [], 'report': None}
                result['parts'].append(entry)
                save()
                try:
                    reference = engine.extract_audio(Path(original['audio']), work / f'audio_{index}.f32')
                    manual = {o['path']: o['offset'] for o in original['overrides'] if o['offset'] is not None}
                    drifts = {o['path']: o['drift_ppm'] for o in original['overrides'] if o.get('drift_ppm') is not None}
                    matched, offsets, syncs = [], [], {}
                    for definition in definitions:
                        clips = []
                        for clip in definition['clips']:
                            camera = copy.copy(cameras[(definition['id'], clip['path'])])
                            try:
                                engine.synchronise(camera, reference, work, manual, drifts, original['drift'], samples)
                            except RuntimeError as exc:
                                warning = f'{definition["id"]} / {Path(clip["path"]).name}: excluded from this excerpt because sync could not be verified. {exc}'
                                entry['warnings'].append(warning)
                                print('WARNING: ' + warning, flush=True)
                                continue
                            clips.append(clip)
                            offsets.append(dict(path=clip['path'], offset=camera.offset, drift_ppm=(camera.rate-1)*1e6))
                            syncs[clip['path']] = camera
                        if clips:
                            matched.append({**definition, 'clips': clips})
                    if not matched:
                        raise ValueError('No camera could be synced to this audio excerpt. Check for overlapping footage or set manual offsets for this excerpt.')
                    part = {**original, 'cameras': matched, 'overrides': offsets}
                    if part['main_camera'] not in {camera['id'] for camera in matched}:
                        part['main_camera'] = matched[0]['id']
                        entry['warnings'].append(f'The main camera could not be synced; using {part["main_camera"]} for this excerpt.')
                    output = Path(part['output_dir'])
                    output.mkdir(parents=True, exist_ok=True)
                    part_report = output / 'Project files' / part['output_name'] / 'Report.json'
                    part_report.parent.mkdir(parents=True, exist_ok=True)
                    # Use the same renderer directly: clips are rendered once at
                    # their correct source position, not cut from a second encode.
                    entry['status']='planning' if part['plan_only'] else 'rendering'
                    save()
                    command = command_for(part, part_report)
                    engine.main(command[len(worker_command('engine')):])
                    detail = json.loads(part_report.read_text(encoding='utf-8'))
                    for sync in detail.get('sync', []):
                        source = syncs[sync['source_path']]
                        sync.update(method=source.sync_method, matched_anchors=source.matched_anchors)
                    detail['warnings'] = entry['warnings']
                    write_json_atomic(part_report, detail)
                    entry.update(status=detail['status'], report=detail)
                    if detail['outputs'].get('video'):
                        result['outputs']['videos'].append(dict(path=detail['outputs']['video'], part_index=index, audio=original['audio']))
                    result['completed_count'] += 1
                except (ValueError, RuntimeError, OSError) as exc:
                    entry.update(status='failed', error=str(exc))
                    print(f'Excerpt {index} failed: {exc}', flush=True)
                save()
            # Release memory maps so Windows can delete the scratch folder.
            samples.clear()
            reference = None
            result['status'] = ('planned' if config['plan_only'] else 'rendered') if result['completed_count'] == result['part_count'] else 'failed'
            save()
            if result['status'] == 'failed':
                raise RuntimeError('One or more audio excerpts failed. Completed outputs are kept; inspect the per-excerpt results.')
    except KeyboardInterrupt:
        result['status'] = 'cancelled'
        if result['parts'] and result['parts'][-1]['status'] in ('synchronising','planning','rendering'):
            result['parts'][-1]['status'] = 'cancelled'
        raise
    except Exception:
        result['status']='failed'
        raise
    finally:
        save()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--report-json', type=Path)
    args = parser.parse_args()
    # Windows cancels with Ctrl+Break; handle it like Ctrl+C so scratch files are removed.
    if hasattr(signal, 'SIGBREAK'):
        signal.signal(signal.SIGBREAK, signal.default_int_handler)
    run_batch(json.loads(args.config.read_text(encoding='utf-8')), args.report_json)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit('Cancelled. Completed excerpt exports have been kept.')
    except Exception as exc:
        sys.exit(f'ERROR: {exc}')
