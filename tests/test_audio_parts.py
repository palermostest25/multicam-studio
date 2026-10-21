import contextlib
import io
import json
from pathlib import Path
import random
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import wave

import numpy as np
import audio_batch
import multicam_edit as engine


def camera(name, end, start=0):
    return engine.Camera(Path(name), name, end/30, 0, 0, 0, True, first=start, last=end)


class CameraCoverageTests(unittest.TestCase):
    def test_ended_camera_is_replaced_until_end_of_audio(self):
        cameras = [camera('A', 900), camera('B', 3000)]
        shots = engine.plan_once(cameras, 3000, 30, [], [], [], random.Random(42), 1)
        self.assertEqual(shots[-1].end, 3000)
        self.assertTrue(all(s.camera == 1 for s in shots if s.start >= 900))
        self.assertFalse(any(s.camera is None for s in shots))
        self.assertTrue(all(s.end <= cameras[s.camera].last for s in shots))

    def test_all_cameras_ending_produces_black_and_forced_missing_angle_errors(self):
        cameras = [camera('A', 900), camera('B', 1800)]
        shots = engine.plan_once(cameras, 3000, 30, [], [], [], random.Random(7), 1)
        self.assertIsNone(shots[-1].camera)
        self.assertEqual((shots[-1].start, shots[-1].end), (1800, 3000))
        with self.assertRaises(ValueError):
            engine.apply_shot_overrides(shots, cameras, [{'start':45,'end':50,'camera_id':'A'}], 30, 100)


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'Requires FFmpeg')
class AudioExcerptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='multicam-audio-parts-')
        cls.root = Path(cls.temp.name).resolve()
        samples = np.random.default_rng(123).normal(0, .15, 32*8000)
        cls.samples = (samples*32767).astype('<i2')
        def wav(path, data):
            with wave.open(str(path),'wb') as f:
                f.setnchannels(1);f.setsampwidth(2);f.setframerate(8000);f.writeframes(data.tobytes())
        wav(cls.root/'master.wav',cls.samples)
        cls.parts=[]
        for index,(start,length) in enumerate([(2,6),(9,6),(23,6.13)],1):
            path=cls.root/f'excerpt{index}.wav'
            wav(path,cls.samples[round(start*8000):round((start+length)*8000)])
            cls.parts.append({'path':str(path)})
        for angle,duration,color in [('A',32,'red'),('B',13,'blue')]:
            subprocess.run(['ffmpeg','-v','error','-nostdin','-y','-f','lavfi','-i',f'color=c={color}:s=160x90:r=30:d={duration}', '-i',str(cls.root/'master.wav'),'-map','0:v:0','-map','1:a:0','-c:v','libx264','-preset','ultrafast','-c:a','pcm_s16le','-t',str(duration),str(cls.root/f'{angle}.MOV')],check=True)
        cls.base={'cameras':[{'id':a,'clips':[{'path':str(cls.root/f'{a}.MOV'),'framing':{'mode':'fit'}}]} for a in ['A','B']], 'audio':cls.parts[0]['path'],'audio_parts':cls.parts,'main_camera':'B','output_name':'set','auto_sections':False,'drift':False,'preset':'ultrafast','crf':25,'fps':30}

    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def setUp(self):
        self.out=tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(self.out.cleanup)
        self.config={**self.base,'output_dir':self.out.name}

    def test_independent_gapped_excerpts_and_early_camera_end(self):
        with patch.object(engine,'output_size',return_value=(160,90)), contextlib.redirect_stdout(io.StringIO()):
            report=audio_batch.run_batch(self.config)
        self.assertEqual(report['completed_count'],3)
        self.assertEqual(len(report['outputs']['videos']),3)
        for index,part in enumerate(report['parts']):
            detail=part['report']
            self.assertEqual(Path(detail['audio']),Path(self.parts[index]['path']))
            sync=next(s for s in detail['sync'] if s['angle']=='A')
            self.assertAlmostEqual(sync['offset_seconds'],-[2,9,23][index],delta=.005)
            self.assertTrue(Path(detail['outputs']['video']).is_file())
            self.assertEqual(Path(detail['outputs']['video']).parent.parent,Path(self.out.name).resolve())
            meta=engine.probe(Path(detail['outputs']['video']))
            audio=next(s for s in meta['streams'] if s['codec_type']=='audio')
            self.assertAlmostEqual(float(audio['duration']),[6,6,6.13][index],delta=.04)
        second=report['parts'][1]['report']
        self.assertTrue(any(s['angle']=='B' for s in second['shots']))
        self.assertTrue(all(s['angle']=='A' for s in second['shots'] if s['start_seconds']>=4))
        self.assertEqual({s['angle'] for s in report['parts'][2]['report']['shots']},{'A'})
        self.assertTrue(report['parts'][2]['warnings'])
        self.assertTrue(all(not p.name.startswith('.multicam') for p in Path(self.out.name).resolve().iterdir()))

    def test_short_excerpt_sync_reuses_camera_audio(self):
        with tempfile.TemporaryDirectory(dir=self.root) as work, contextlib.redirect_stdout(io.StringIO()):
            cam=engine.read_camera(self.root/'A.MOV','A');cache={}
            reference=engine.extract_audio(Path(self.parts[2]['path']),Path(work)/'bounce.f32')
            with patch.object(engine,'extract_audio',wraps=engine.extract_audio) as extract:
                engine.synchronise(cam,reference,Path(work),{},{},False,cache)
                engine.synchronise(cam,reference,Path(work),{},{},False,cache)
            self.assertEqual(extract.call_count,1)
            self.assertAlmostEqual(cam.offset,-23,delta=.005)

    def test_failure_keeps_other_excerpts_and_reports_the_failed_one(self):
        silent = self.root/'silent.wav'
        with wave.open(str(silent),'wb') as f:
            f.setnchannels(1);f.setsampwidth(2);f.setframerate(8000);f.writeframes(bytes(6*8000*2))
        config={**self.config,'audio_parts':[self.parts[0],{'path':str(silent)},self.parts[2]]}
        with patch.object(engine,'output_size',return_value=(160,90)), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError,'One or more audio excerpts failed'):
                audio_batch.run_batch(config)
        manifest=json.loads((Path(self.out.name)/'set_audio_parts.json').read_text())
        self.assertEqual(manifest['status'],'failed')
        self.assertEqual(manifest['completed_count'],2)
        self.assertEqual(manifest['parts'][1]['status'],'failed')
        self.assertTrue(all(Path(v['path']).is_file() for v in manifest['outputs']['videos']))

    def test_cancel_keeps_completed_excerpt_and_manifest(self):
        real_main=engine.main
        calls=0
        def main(argv=None):
            nonlocal calls
            calls+=1
            if calls==2:raise KeyboardInterrupt()
            return real_main(argv)
        with patch.object(engine,'output_size',return_value=(160,90)), patch.object(engine,'main',side_effect=main), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(KeyboardInterrupt):audio_batch.run_batch(self.config)
        manifest=json.loads((Path(self.out.name)/'set_audio_parts.json').read_text())
        self.assertEqual(manifest['status'],'cancelled')
        self.assertEqual(manifest['completed_count'],1)
        self.assertTrue(Path(manifest['outputs']['videos'][0]['path']).is_file())
        self.assertEqual(manifest['parts'][-1]['status'],'cancelled')

    def test_preflight_isolates_sibling_outputs_and_part_timing(self):
        raw={**self.config,'audio_parts':[{**self.parts[0],'overrides':[{'path':str(self.root/'A.MOV'),'offset':-2}]},self.parts[1],self.parts[2]]}
        config=audio_batch.validate_config(raw)
        self.assertTrue(all(Path(c['output_dir']).parent==Path(self.out.name).resolve() for c in config['part_configs']))
        self.assertEqual(config['part_configs'][0]['overrides'][0]['offset'],-2)
        self.assertEqual(config['part_configs'][1]['overrides'],[])
        target=Path(config['part_configs'][2]['output_dir']);target.mkdir();(target/'keep.txt').write_text('keep')
        with self.assertRaisesRegex(ValueError,'already exists'):
            audio_batch.validate_config(raw)
        self.assertFalse(Path(config['part_configs'][0]['output_dir']).exists())

if __name__=='__main__':unittest.main()
