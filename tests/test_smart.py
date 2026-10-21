import contextlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import wave

import numpy as np

import multicam_edit as engine
import music
import planner


def dance_track(bpm=128.0, seconds=96, breakdown=(32, 48), sr=8000, seed=3):
    """Kick on every beat, hats off-beat, a breakdown with no kick or bass."""
    rng = np.random.default_rng(seed)
    t = np.arange(int(seconds * sr)) / sr
    x = 0.004 * rng.normal(size=len(t))
    beat = 60 / bpm
    for k in range(int(seconds / beat)):
        start = k * beat
        i = int(start * sr)
        n = int(0.12 * sr)
        tt = np.arange(n) / sr
        in_breakdown = breakdown[0] <= start < breakdown[1]
        if not in_breakdown:
            x[i:i + n] += 0.9 * np.sin(2 * np.pi * 55 * tt) * np.exp(-tt * 25)[:len(x[i:i + n])]
        j = int((start + beat / 2) * sr)
        m = int(0.03 * sr)
        x[j:j + m] += 0.25 * rng.normal(size=len(x[j:j + m])) * np.exp(-np.arange(len(x[j:j + m])) / sr * 120)
        if k % 4 == 0 and not in_breakdown:  # bass stab on every bar line
            b = int(0.4 * sr)
            x[i:i + b] += 0.4 * np.sin(2 * np.pi * 82 * np.arange(len(x[i:i + b])) / sr)
    pad = 0.15 * np.sin(2 * np.pi * 440 * t) * ((t >= breakdown[0]) & (t < breakdown[1]))
    return (x + pad).astype(np.float32)


class Cam:
    def __init__(self, angle, first, last):
        self.angle, self.first, self.last = angle, first, last


class MusicTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.result = music.analyse(dance_track())

    def test_tempo_and_beat_grid(self):
        self.assertAlmostEqual(self.result['bpm'], 128.0, delta=1.0)
        self.assertGreater(self.result['confidence'], 0.5)
        beats = np.array(self.result['beats'])
        steady = np.abs(np.diff(beats) - 60 / 128) < 0.03
        self.assertGreater(steady.mean(), 0.9)  # only the kick-less breakdown edges may wobble

    def test_breakdown_build_and_drop(self):
        kinds = {s['kind'] for s in self.result['sections']}
        self.assertIn('breakdown', kinds)
        self.assertTrue(self.result['drops'])
        self.assertAlmostEqual(self.result['drops'][0], 48.0, delta=2.0)

    def test_snap(self):
        self.assertEqual(music.snap(10.02, [9.5, 10.0, 10.5], 0.1), 10.0)
        self.assertEqual(music.snap(10.3, [9.5, 10.0], 0.1), 10.3)


class PlannerTests(unittest.TestCase):
    fps = 30

    def music(self):
        return music.analyse(dance_track())

    def test_no_flash_frames_and_cuts_on_beats(self):
        info = self.music()
        total = 96 * self.fps
        cams = [Cam('A', 0, total), Cam('B', 0, total), Cam('C', 0, total)]
        shots = planner.plan(cams, total, self.fps, info, [s for s in info['sections'] if s['kind'] != 'normal'],
                             seed=7, main_camera='A', rhythm=planner.Rhythm(cut_scale=0.5))
        self.assertEqual(shots[0].start, 0)
        self.assertEqual(shots[-1].end, total)
        self.assertTrue(all(a.end == b.start for a, b in zip(shots, shots[1:])))
        self.assertTrue(all((s.end - s.start) / self.fps >= 0.6 for s in shots[:-1]))
        self.assertFalse(any(s.camera is None for s in shots))
        beats = set(round(t * self.fps) for t in info['beats'])
        on_beat = sum(1 for s in shots[1:] if any(abs(s.start - b) <= 1 for b in beats))
        self.assertGreaterEqual(on_beat / max(1, len(shots) - 1), 0.8)

    def test_hands_over_when_a_camera_ends_and_black_only_without_footage(self):
        total = 3000
        cams = [Cam('A', 0, 900), Cam('B', 0, 1800)]
        shots = planner.plan(cams, total, self.fps, None, seed=1, main_camera='A')
        self.assertTrue(all(s.camera == 1 for s in shots if 900 <= s.start < 1800))
        self.assertEqual([(s.start, s.end) for s in shots if s.camera is None], [(1800, 3000)])

    def test_poor_picture_is_avoided(self):
        total = 60 * self.fps
        cams = [Cam('A', 0, total), Cam('B', 0, total)]
        steps = int(np.ceil(total / self.fps / planner.Scores.STEP)) + 2
        bad_a = ([1.0] * 40 + [0.0] * 40 + [1.0] * (steps - 80), [0.5] * steps)
        scores = planner.build_scores(cams, total, self.fps, [bad_a, None])
        shots = planner.plan(cams, total, self.fps, None, seed=2, main_camera='A', scores=scores)
        a_in_bad = sum(min(s.end, 40 * self.fps) - max(s.start, 20 * self.fps)
                       for s in shots if s.camera == 0 and s.end > 20 * self.fps and s.start < 40 * self.fps)
        self.assertLess(a_in_bad, 0.25 * 20 * self.fps)

    def test_clip_windows_are_bar_aligned_and_fully_covered(self):
        info = self.music()
        total = 96 * self.fps
        cams = [Cam('A', 0, 70 * self.fps)]
        windows = planner.window_scores(info, cams, total, self.fps, 15, ending='bar')
        self.assertTrue(windows)
        downbeats = info['downbeats']
        for w in windows:
            self.assertLessEqual(w['end'], 70 + 1e-6)
            self.assertTrue(any(abs(w['start'] - d) < 1e-3 for d in downbeats))
            self.assertAlmostEqual(w['end'] - w['start'], 8 * 4 * 60 / 128, delta=0.6)
        best = planner.choose_clips(windows, 2, 'best')
        self.assertEqual(len(best), 2)
        self.assertLessEqual(best[0]['end'], best[1]['start'] + 1e-6)
        sequence = planner.choose_clips(windows, 0, 'sequence')
        self.assertTrue(all(a['end'] <= b['start'] + 1e-6 for a, b in zip(sequence, sequence[1:])))

    def test_clips_end_on_the_beat_or_at_the_bar_line(self):
        info = self.music()
        total = 96 * self.fps
        cams = [Cam('A', 0, total)]
        beat = planner.window_scores(info, cams, total, self.fps, 15, ending='beat')
        bar = planner.window_scores(info, cams, total, self.fps, 15, ending='bar')
        bar_ends = {w['start']: w['end'] for w in bar}
        self.assertTrue(beat)
        for w in beat:
            # One beat past the bar line, so the next downbeat is heard.
            self.assertAlmostEqual(w['tail'], 60 / 128, delta=0.3 * 60 / 128)
            if w['start'] in bar_ends:
                self.assertAlmostEqual(w['end'] - w['tail'], bar_ends[w['start']], delta=1e-3)
        self.assertTrue(all(w['tail'] == 0 for w in bar))


class ClipFramingTests(unittest.TestCase):
    def camera(self, w, h, framing=None):
        c = engine.Camera(Path('x.mov'), 'A', 10, 0, 0, 0, True, width=w, height=h)
        c.framing = framing
        return c

    def test_smart_fits_wide_shots_and_crops_close_matches(self):
        crop = {'mode': 'crop', 'center': [0.3, 0.5], 'zoom': 1, 'auto': False}
        self.assertEqual(engine.clip_framing(self.camera(1920, 1080, crop), '9:16', 'smart')['mode'], 'fit')
        self.assertEqual(engine.clip_framing(self.camera(1080, 1920, crop), '9:16', 'smart')['mode'], 'crop')
        self.assertEqual(engine.clip_framing(self.camera(1920, 1080, crop), '16:9', 'smart')['mode'], 'crop')
        self.assertEqual(engine.clip_framing(self.camera(1920, 1080, {'mode': 'fit'}), '9:16', 'crop')['mode'], 'crop')
        self.assertEqual(engine.clip_framing(self.camera(1920, 1080, crop), '9:16', 'same'), crop)

    def test_clip_lengths_parse(self):
        self.assertEqual(engine.clip_lengths('30, 15,15,60'), [15.0, 30.0, 60.0])
        for bad in ('', '2', 'x', '15,9999'):
            with self.assertRaises(Exception):
                engine.clip_lengths(bad)


class FormatTests(unittest.TestCase):
    def test_frame_sizes(self):
        self.assertEqual(engine.frame_size('16:9', 2160), (3840, 2160))
        self.assertEqual(engine.frame_size('9:16', 1080), (1080, 1920))
        self.assertEqual(engine.frame_size('4:5', 1080), (1080, 1350))
        self.assertEqual(engine.frame_size('1:1', 720), (720, 720))

    def test_fit_uses_blurred_fill_not_black_bars(self):
        blurred = engine.framing_filter({'mode': 'fit'}, (1080, 1920))
        self.assertIn('boxblur', blurred)
        self.assertNotIn('pad=', blurred)
        self.assertIn('pad=', engine.framing_filter({'mode': 'pad'}, (1080, 1920)))

    def test_auto_framing_uses_focus(self):
        f = engine.framing_filter({'mode': 'crop', 'center': [0.5, 0.5], 'auto': True}, (1080, 1920), [0.25, 0.4])
        self.assertIn('iw*0.25', f)
        self.assertIn('ih*0.4', f)


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'Requires FFmpeg')
class ClipExportTests(unittest.TestCase):
    def test_vertical_clips_render_from_sources(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            samples = (dance_track(seconds=40, breakdown=(12, 20)) * 32767 * 0.5).astype('<i2')
            with wave.open(str(root / 'set.wav'), 'wb') as f:
                f.setnchannels(1); f.setsampwidth(2); f.setframerate(8000); f.writeframes(samples.tobytes())
            for name, colour, size in [('a', 'red', '320x180'), ('b', 'blue', '320x180'), ('c', 'green', '180x320')]:
                subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-y', '-f', 'lavfi', '-i', f'color=c={colour}:s={size}:r=30:d=40',
                                '-i', str(root / 'set.wav'), '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'libx264', '-preset', 'ultrafast',
                                '-c:a', 'pcm_s16le', '-t', '40', str(root / f'{name}.mov')], check=True)
            project = root / 'project.json'
            project.write_text(json.dumps({'cameras': [
                {'id': 'A', 'clips': [{'path': str(root / 'a.mov'), 'framing': {'mode': 'crop'}}]},
                {'id': 'B', 'clips': [{'path': str(root / 'b.mov'), 'framing': {'mode': 'fit'}}]},
                {'id': 'C', 'clips': [{'path': str(root / 'c.mov'), 'framing': {'mode': 'pad'}}]}]}), encoding='utf-8')
            with contextlib.redirect_stdout(io.StringIO()):
                engine.main(['--project', str(project), '--audio', str(root / 'set.wav'), '--output-dir', str(root / 'out'),
                             '--resolution', '720', '--clips', '7,5', '--clip-count', '2', '--clip-resolution', '720',
                             '--clips-only', '--no-drift', '--preset', 'ultrafast', '--encoder', 'software', '--vision', 'off'])
            report = json.loads((root / 'out' / 'report_horizontal.json').read_text(encoding='utf-8'))
            self.assertEqual(report['status'], 'rendered')
            self.assertIsNone(report['outputs']['video'])
            self.assertEqual(len(report['clips']), 4)
            self.assertEqual(sorted({c['length'] for c in report['clips']}), [5, 7])
            for clip in report['clips']:
                self.assertIn(f"/Social media/{round(clip['length'])}s/", clip['path'])
                info = engine.probe(Path(clip['path']))
                video = next(s for s in info['streams'] if s['codec_type'] == 'video')
                self.assertEqual((video['width'], video['height']), (720, 1280))
                self.assertAlmostEqual(float(info['format']['duration']), clip['end'] - clip['start'], delta=0.1)
            self.assertEqual(len([v for v in report['outputs']['videos'] if not v.get('alternative')]), 4)
            # Clips that use the vertical camera C also get a 9:16 copy in Social media alternatives.
            alternatives = [c for c in report['clips'] if c.get('alternative_path')]
            self.assertTrue(alternatives)
            for clip in alternatives:
                self.assertIn(f"/Social media alternatives/{round(clip['length'])}s/", clip['alternative_path'])
                self.assertEqual(Path(clip['alternative_path']).name, Path(clip['path']).name)
                info = engine.probe(Path(clip['alternative_path']))
                video = next(s for s in info['streams'] if s['codec_type'] == 'video')
                self.assertEqual((video['width'], video['height']), (720, 1280))

    def test_social_media_alternatives_for_clips_with_vertical_footage(self):
        base = dict(duration=100, video_start=0, format_start=0, audio_start=0, has_audio=True)
        cams = [engine.Camera(Path('a.mov'), 'A', width=1920, height=1080, framing={'mode': 'fit'}, **base),
                engine.Camera(Path('c.mov'), 'C', width=1080, height=1920, framing={'mode': 'pad'}, **base)]
        self.assertEqual(engine.alternative_framing(cams[0])['mode'], 'pad')
        tall = engine.alternative_framing(cams[1])
        self.assertEqual((tall['mode'], tall['zoom']), ('crop', 1))
        self.assertFalse(engine.is_vertical(cams[0])); self.assertTrue(engine.is_vertical(cams[1]))


class ServerTests(unittest.TestCase):
    def test_export_subfolder_stays_inside_exports(self):
        import server
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            studio = server.Studio(root / 'state', root, root / 'exports', remote=True)
            self.assertEqual(studio.export_subfolder('Reels/Friday'), (root / 'exports' / 'Reels' / 'Friday'))
            self.assertEqual(studio.export_subfolder(''), root / 'exports')
            for bad in ('../escape', 'a/../../b', '.hidden', 'a/b/c/d'):
                with self.assertRaises(ValueError):
                    studio.export_subfolder(bad)

    def test_new_settings_validate(self):
        import server
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'a.mov').write_bytes(b'x'); (root / 'set.flac').write_bytes(b'x')
            base = {'cameras': [{'id': 'A', 'clips': [{'path': str(root / 'a.mov'), 'framing': {'mode': 'fit', 'auto': True}}]}],
                    'audio': str(root / 'set.flac'), 'output_dir': str(root / 'out')}
            config = server.validate_config({**base, 'aspect': '4:5', 'resolution': 1080, 'codec': 'hevc', 'clips': 15,
                                             'clip_lengths': [60, 15, 30], 'clip_framing': 'fit'})
            self.assertEqual(config['mode'], 'vertical')
            command = server.command_for(config, root / 'report.json')
            self.assertEqual(command[command.index('--clips') + 1], '15,30,60')
            self.assertEqual(command[command.index('--clip-framing') + 1], 'fit')
            # A Mac app project with clips switched off keeps them off.
            self.assertEqual(server.validate_config({**base, 'clips': 0, 'clip_lengths': [15, 30]})['clip_lengths'], [])
            self.assertEqual(server.validate_config({**base, 'clips': '15,30'})['clip_lengths'], [15, 30])
            self.assertEqual(command[command.index('--codec') + 1], 'hevc')
            self.assertEqual(command[command.index('--engine') + 1], '2')
            engine_one = server.command_for(server.validate_config({**base, 'engine': '1'}), root / 'report.json')
            self.assertEqual(engine_one[engine_one.index('--engine') + 1], '1')
            for bad in ({'aspect': '2:1'}, {'resolution': 999}, {'codec': 'vp9'}, {'clips': 1}, {'clip_framing': 'zoom'},
                        {'engine': 3}, {'engine': 'new'}):
                with self.assertRaises(ValueError):
                    server.validate_config({**base, **bad})


if __name__ == '__main__':
    unittest.main()
