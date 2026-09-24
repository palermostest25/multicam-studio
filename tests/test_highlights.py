"""Regression checks: python3 -m unittest discover -s tests -v."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

import effects
from highlights import plan_clips


class PlanningTests(unittest.TestCase):
    def test_whole_recording_including_late_peaks(self):
        values = np.full(3600, .05)
        for start in range(20, 3600, 100):
            values[start:start + 15] = .9
        clips = plan_clips(values, 3600, 20)
        self.assertGreater(len(clips), 20)
        self.assertGreater(clips[-1]['end'], 3500)
        self.assertTrue(all(19 <= c['end'] - c['start'] <= 21 for c in clips))
        self.assertTrue(all(a['end'] <= b['start'] for a, b in zip(clips, clips[1:])))
        self.assertEqual(clips, plan_clips(values, 3600, 20))

    def test_long_drop_is_chopped_and_length_changes_count(self):
        values = np.full(1200, .1)
        values[420:640] = .9
        short = plan_clips(values, 1200, 15)
        long = plan_clips(values, 1200, 60)
        self.assertGreater(len(short), len(long))
        self.assertGreater(short[-1]['end'], 639)
        self.assertLess(short[0]['start'], 421)
        self.assertTrue(all(10 <= c['end'] - c['start'] <= 22.5 for c in short))

    def test_edges_and_short_sources(self):
        values = np.full(1000, .1)
        values[:30] = 1
        values[-30:] = 1
        clips = plan_clips(values, 100, 15)
        self.assertEqual(clips[0]['start'], 0)
        self.assertEqual(clips[-1]['end'], 100)
        self.assertTrue(all(0 <= c['start'] < c['end'] <= 100 for c in clips))
        short = plan_clips([.1] * 10 + [.9] * 10 + [.1] * 10, 3, 30)
        self.assertEqual([(c['start'], c['end']) for c in short], [(0, 3)])

    def test_silence_constant_noise_and_bad_length(self):
        for values in [np.zeros(1000), np.ones(1000) * .7]:
            self.assertEqual(plan_clips(values, 100), [])
        self.assertEqual(plan_clips([0, 1, 0], 10, maximum=1e-8), [])
        for length in [True, None, float('nan'), float('inf'), -2, 0, 301]:
            with self.assertRaises(ValueError):
                plan_clips([0, 1, 0], 10, length)


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'Requires FFmpeg on PATH')
class ExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix='multicam-tests-')
        cls.root = Path(cls.workspace.name)
        cls.source = cls.root / 'test-source.MOV'
        subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-y',
            '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=30:duration=12',
            '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=12',
            '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
            '-c:a', 'aac', '-ac', '2', '-t', '12', str(cls.source)], check=True)
        cls.original = cls.source.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(self.folder.cleanup)
        self.config = {'source_path': str(self.source), 'output_dir': self.folder.name,
                       'output_name': 'test', 'preset': 'ultrafast', 'crf': 22,
                       'clips': [{'start': 1.2, 'end': 3.2}, {'start': 8, 'end': 10.5}]}

    def test_batch_exports_correct_ranges_audio_and_progress(self):
        log = io.StringIO()
        with contextlib.redirect_stdout(log):
            report = effects.render_batch(self.config)
        self.assertEqual(report['completed_count'], 2)
        self.assertEqual(report['status'], 'rendered')
        for clip in report['clips']:
            meta = effects.probe(Path(clip['path']))
            video = next(s for s in meta['streams'] if s['codec_type'] == 'video')
            audio = next(s for s in meta['streams'] if s['codec_type'] == 'audio')
            self.assertEqual((video['width'], video['height']), (160, 90))
            self.assertEqual(video['avg_frame_rate'], '30/1')
            self.assertEqual(audio['channels'], 2)
            self.assertAlmostEqual(float(video['duration']), clip['end'] - clip['start'], delta=.04)
        times = [float(line.split('=')[1]) for line in log.getvalue().splitlines() if line.startswith('progress_seconds=')]
        self.assertEqual(times, sorted(times))
        self.assertAlmostEqual(times[-1], 4.5)
        manifest = json.loads(Path(report['outputs']['report']).read_text())
        self.assertEqual(manifest['clips'], report['clips'])
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_every_style_actually_renders(self):
        for style in sorted(effects.STYLES):
            with self.subTest(style=style), contextlib.redirect_stdout(io.StringIO()):
                result = effects.render({**self.config, 'style': style, 'output_name': style,
                                         'start': 0, 'end': .5})
                self.assertTrue(Path(result['outputs']['video']).is_file())

    def test_preflight_protects_later_collisions_and_source(self):
        configs = effects.validate_batch(self.config)['clip_configs']
        collision = Path(configs[1]['output_path'])
        collision.write_bytes(b'keep me')
        with self.assertRaises(ValueError):
            effects.render_batch(self.config)
        self.assertEqual(collision.read_bytes(), b'keep me')
        self.assertFalse(Path(configs[0]['output_path']).exists())
        collision.unlink()
        os.link(self.source, collision)
        with self.assertRaisesRegex(ValueError, 'source movie'):
            effects.validate_batch({**self.config, 'overwrite': True})
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_cancel_and_failure_preserve_completed_clips(self):
        real_render = effects.render
        for error in [KeyboardInterrupt(), RuntimeError('test render failure')]:
            with self.subTest(error=type(error).__name__):
                config = {**self.config, 'output_name': type(error).__name__}
                calls = 0
                def render(*args, **kwargs):
                    nonlocal calls
                    calls += 1
                    if calls == 2:
                        raise error
                    return real_render(*args, **kwargs)
                with patch.object(effects, 'render', side_effect=render), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(type(error)):
                        effects.render_batch(config)
                manifest = json.loads((Path(self.folder.name) / (config['output_name'] + '_highlights.json')).read_text())
                self.assertEqual(manifest['completed_count'], 1)
                self.assertEqual(manifest['status'], 'cancelled' if isinstance(error, KeyboardInterrupt) else 'failed')
                self.assertTrue(Path(manifest['clips'][0]['path']).is_file())
                self.assertFalse(any(p.name.startswith('.multicam-') for p in Path(self.folder.name).iterdir()))

    def test_invalid_ranges_and_filename(self):
        for ranges in [[], [{'start': 2, 'end': 3}, {'start': 1, 'end': 2}],
                       [{'start': 0, 'end': 13}], [{'start': 1, 'end': 1}], [{'start': float('nan'), 'end': 2}]]:
            with self.assertRaises(ValueError):
                effects.validate_batch({**self.config, 'clips': ranges})
        for name in ['../escape', 'a/b', 'a\\b', '.']:
            with self.assertRaises(ValueError):
                effects.validate_batch({**self.config, 'output_name': name})


if __name__ == '__main__':
    unittest.main()
