#!/usr/bin/env python3
"""Multicam Studio: a loopback-only UI and job runner for multicam_edit.py.

    python3 server.py --open --default-folder /Volumes/External/TRADES

Only Python's standard library is used by this server; the editor needs NumPy,
SciPy, ffmpeg and ffprobe. By default the browser and render worker run on the
same computer (macOS, Windows or Linux). Server mode (--host 0.0.0.0, used by the
Docker image) serves the same interface to other machines on the network.

Every option can also be set with an environment variable, such as
MULTICAM_HOST, MULTICAM_PORT, MULTICAM_STATE_DIR, MULTICAM_DEFAULT_FOLDER,
MULTICAM_DEFAULT_OUTPUT, MULTICAM_ROOTS, MULTICAM_ALLOWED_HOSTS and
MULTICAM_PASSWORD.
"""
from __future__ import annotations
import argparse
import base64
import errno
import platform
import tempfile
import urllib.request
import datetime as dt
import importlib.util
import hashlib
import json
import math
import mimetypes
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse, quote
import webbrowser

WINDOWS = os.name == 'nt'
if WINDOWS:
    import msvcrt
else:
    import fcntl

APP = Path(__file__).resolve().parent
VERSION = '1.2.0'
APP_ID = 'com.multicamstudio.desktop'
DISCONNECTS = (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, TimeoutError)
_RUNNING_SERVER = None
VIDEO_EXTS = {'.mp4', '.mov'}
AUDIO_EXTS = {'.wav'}
PRESETS = {'ultrafast','superfast','veryfast','faster','fast','medium','slow'}
LOOPBACK = {'127.0.0.1','localhost'}
# Workers print file names; keep their pipes UTF-8 whatever the Windows code page.
UTF8 = {'encoding':'utf-8','errors':'replace'}


def default_media_folder():
    return Path.home()/('Videos' if WINDOWS else 'Movies')


def default_roots():
    """Places offered by the file browser: home, drives and attached volumes."""
    roots=[str(Path.home())]
    if WINDOWS:
        roots += [f'{letter}:\\' for letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' if os.path.isdir(f'{letter}:\\')]
    else:
        for mounts in (Path('/Volumes'),Path('/media'),Path('/mnt')):
            try:
                if mounts.is_dir(): roots.extend(str(p) for p in sorted(mounts.iterdir()) if p.is_dir())
            except OSError: pass
    return roots


def worker_environment():
    return {**os.environ,'PYTHONUTF8':'1','PYTHONIOENCODING':'utf-8'}


def spawn_options():
    """Put each worker in its own process group so cancelling also stops FFmpeg."""
    if WINDOWS:
        return {'creationflags':subprocess.CREATE_NEW_PROCESS_GROUP}
    return {'start_new_session':True}


def signal_worker(proc,stage):
    """stage is 'interrupt' (clean up and exit), 'terminate' or 'kill'."""
    if proc.poll() is not None: return
    if WINDOWS:
        if stage=='interrupt':
            try:
                os.kill(proc.pid,signal.CTRL_BREAK_EVENT);return
            except OSError: pass  # No shared console: stop the tree immediately.
        subprocess.run(['taskkill','/PID',str(proc.pid),'/T','/F'],capture_output=True)
        return
    sig={'interrupt':signal.SIGINT,'terminate':signal.SIGTERM,'kill':signal.SIGKILL}[stage]
    try: os.killpg(proc.pid,sig)
    except ProcessLookupError: pass


def resolved(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError('Choose a file or folder first.')
    return Path(value).expanduser().resolve()


def finite(value, label, low=None, high=None, integer=False):
    if isinstance(value, bool):
        raise ValueError(f'{label} must be a number.')
    try:
        n = float(value)
    except (ValueError, TypeError):
        raise ValueError(f'{label} must be a number.')
    if not math.isfinite(n) or (low is not None and n < low) or (high is not None and n > high):
        raise ValueError(f'{label} is outside its allowed range.')
    if integer:
        if n != int(n):
            raise ValueError(f'{label} must be a whole number.')
        return int(n)
    return n


def validate_framing(value):
    if not isinstance(value,dict):raise ValueError('Invalid clip framing.')
    mode=value.get('mode','fit')
    if mode not in ('fit','crop'):raise ValueError('Framing must fit the full picture or crop it.')
    centre=value.get('center',[.5,.5])
    if not isinstance(centre,list) or len(centre)!=2:raise ValueError('Crop centre needs X and Y.')
    return {'mode':mode,'center':[finite(x,'Crop centre',0,1) for x in centre],
            'zoom':finite(value.get('zoom',1),'Crop zoom',1,8)}


def validate_config(raw):
    if not isinstance(raw, dict):
        raise ValueError('Expected editing settings.')
    c = dict(raw)
    all_inputs = []
    cameras = c.get('cameras')
    if cameras is not None:
        if not isinstance(cameras,list) or not cameras:
            raise ValueError('Add at least one camera.')
        clean=[];ids=set()
        for index,camera in enumerate(cameras):
            if not isinstance(camera,dict):raise ValueError('Each camera needs an identifier and clip list.')
            ident=str(camera.get('id','')).strip()
            if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,31}',ident) or ident.upper()=='BLACK' or ident in ids:
                raise ValueError('Camera identifiers must be unique names such as A, B or Cam3.')
            ids.add(ident)
            clips=camera.get('clips',[])
            if not isinstance(clips,list) or not clips:raise ValueError(f'Add recordings to camera {ident}.')
            clean_clips=[]
            for clip in clips:
                if not isinstance(clip,dict):raise ValueError('Each clip needs a file path.')
                path=resolved(clip.get('path'))
                if not path.is_file() or path.suffix.lower() not in VIDEO_EXTS:raise ValueError(f'Not a MOV or MP4 file: {path}')
                framing=validate_framing(clip.get('framing',{'mode':'fit'}))
                clean_clips.append({'path':str(path),'framing':framing});all_inputs.append(path)
            clean.append({'id':ident,'label':str(camera.get('label') or ident)[:100],'clips':clean_clips})
        c['cameras']=clean
        c['main_camera']=str(c.get('main_camera',clean[0]['id']))
        if c['main_camera'] not in ids:raise ValueError('Choose a main camera from your camera list.')
    else:
        for key in ('cam_a','cam_b'):
            values = c.get(key)
            if not isinstance(values,list) or not values:
                raise ValueError(f'Choose at least one file for Camera {key[-1].upper()}.')
            paths = [resolved(x) for x in values]
            for path in paths:
                if not path.is_file() or path.suffix.lower() not in VIDEO_EXTS:
                    raise ValueError(f'Not a readable MOV or MP4 file: {path}')
            c[key] = [str(path) for path in paths]
            all_inputs += paths
        c['main_camera']=str(c.get('main_camera','A'))
        if c['main_camera'] not in ('A','B'):raise ValueError('Choose A or B as the main camera.')
    overrides=c.get('shot_overrides',[])
    if not isinstance(overrides,list):raise ValueError('Shot overrides must be a list.')
    c['shot_overrides']=[]
    for item in overrides:
        if not isinstance(item,dict):raise ValueError('Each shot override needs a start, end and camera.')
        a=finite(item.get('start'),'Override start',0);b=finite(item.get('end'),'Override end',0)
        if b<=a:raise ValueError('A shot override must end after it starts.')
        camera_id=str(item.get('camera_id',''))
        known={x['id'] for x in c['cameras']} if cameras is not None else {'A','B'}
        if camera_id not in known:raise ValueError('A shot override refers to a missing camera.')
        entry={'start':a,'end':b,'camera_id':camera_id}
        if item.get('source_path'):
            entry['source_path']=str(resolved(item['source_path']))
            selected=next((cam['clips'] for cam in c.get('cameras',[]) if cam['id']==camera_id),[])
            if entry['source_path'] not in {clip['path'] for clip in selected}:
                raise ValueError('A shot override must use a clip belonging to its selected camera.')
        c['shot_overrides'].append(entry)
    ordered=sorted(c['shot_overrides'],key=lambda x:x['start'])
    if any(right['start']<left['end'] for left,right in zip(ordered,ordered[1:])):
        raise ValueError('Shot overrides cannot overlap. Adjust their start and end times.')
    if len(set(all_inputs)) != len(all_inputs):
        raise ValueError('The same recording is selected more than once.')
    audio = resolved(c.get('audio'))
    if not audio.is_file() or audio.suffix.lower() not in AUDIO_EXTS:
        raise ValueError('Choose a WAV audio bounce.')
    c['audio'] = str(audio)
    out = resolved(c.get('output_dir'))
    if out.exists() and not out.is_dir():
        raise ValueError('The output location must be a folder.')
    c['output_dir'] = str(out)
    name = str(c.get('output_name') or '').strip()
    if name.lower().endswith('.mp4'):
        name = name[:-4]
    if name and (not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9 ._-]{0,119}',name) or name.endswith((' ','.'))):
        raise ValueError('Output name must start with a letter or number and use only letters, numbers, spaces, dots, underscores or hyphens (up to 120 characters).')
    c['output_name'] = name
    for key, choices, default in [('mode',{'horizontal','vertical'},'horizontal'),('preset',PRESETS,'medium')]:
        c[key] = c.get(key,default)
        if c[key] not in choices:
            raise ValueError(f'Invalid {key.replace("_"," ")}.')
    for key,default,lo,hi,integer in [('seed',42,-2147483648,2147483647,True),('fps',30,1,60,True),('crf',18,0,51,True),('cut_scale',1,0.05,20,False),('main_share',.7,.05,.95,False)]:
        c[key] = finite(c.get(key,default),key,lo,hi,integer)
    if c['fps'] not in (24,25,30,50,60):
        raise ValueError('Choose 24, 25, 30, 50 or 60 fps.')
    for key,default in [('a_center',[.5,.5]),('b_center',[.5,.72])]:
        pair=c.get(key,default)
        if not isinstance(pair,list) or len(pair)!=2:
            raise ValueError(f'{key} needs X and Y.')
        c[key]=[finite(v,key,0,1) for v in pair]
    for key,default in [('main_hold',[20,60]),('cutaway_hold',[4,12]),('drop_hold',[3,6]),('breakdown_hold',[15,30])]:
        pair=c.get(key,default)
        if not isinstance(pair,list) or len(pair)!=2:
            raise ValueError(f'{key} needs a minimum and maximum.')
        c[key]=[finite(v,key,.1,3600) for v in pair]
        if c[key][0]>c[key][1]:
            raise ValueError(f'{key}: minimum cannot exceed maximum.')
    for key in ('drops','breakdowns'):
        values=c.get(key,[])
        if not isinstance(values,list) or len(values)>1000:
            raise ValueError(f'Invalid {key} markers.')
        c[key]=[]
        for pair in values:
            if not isinstance(pair,list) or len(pair)!=2:
                raise ValueError(f'{key} requires start/end pairs.')
            a,b=[finite(v,key,0) for v in pair]
            if b<=a:
                raise ValueError(f'{key}: end must be after start.')
            c[key].append([a,b])
    activities=c.get('activities',[])
    if not isinstance(activities,list) or len(activities)>10000:
        raise ValueError('Invalid action markers.')
    c['activities']=[finite(v,'Action time',0) for v in activities]
    for key,default in [('auto_sections',True),('drift',True),('overwrite',False),('plan_only',False)]:
        if not isinstance(c.get(key,default),bool):
            raise ValueError(f'{key} must be on or off.')
        c[key]=c.get(key,default)
    overrides=c.get('overrides',[])
    if not isinstance(overrides,list) or len(overrides)>200:
        raise ValueError('Invalid sync overrides.')
    c['overrides']=[]
    seen=set()
    for item in overrides:
        if not isinstance(item,dict):raise ValueError('Each sync override needs a file path.')
        p=resolved(item.get('path'))
        if p not in all_inputs or p in seen:
            raise ValueError('A sync override must identify a selected recording once.')
        seen.add(p)
        off=item.get('offset'); ppm=item.get('drift_ppm')
        if off is not None:
            off=finite(off,'Manual offset')
        if ppm is not None:
            ppm=finite(ppm,'Clock drift',-2000,2000)
            if off is None:
                if ppm == 0: ppm=None
                else: raise ValueError('A manual clock drift also needs a manual offset.')
        c['overrides'].append({'path':str(p),'offset':off,'drift_ppm':ppm})
    return c


def worker_command(kind):
    """Use explicit entrypoint dispatch in a frozen app; Python scripts in source installs."""
    if getattr(sys, 'frozen', False):
        return [sys.executable, '--' + kind]
    return [sys.executable, '-u', str(APP / ('multicam_edit.py' if kind == 'engine' else 'effects.py'))]


def writable_folder(path):
    path.mkdir(parents=True, exist_ok=True)
    if not path.is_dir():
        raise ValueError('Choose a folder, not a file.')
    try:
        with tempfile.TemporaryFile(dir=path):
            pass
    except OSError as exc:
        raise ValueError('Cannot write to that folder. Choose another folder or check its permissions.') from exc
    return path


def command_for(c, report):
    cmd=worker_command('engine')
    if c.get('cameras'):
        project=report.parent/'project.json'
        project.write_text(json.dumps({'cameras':c['cameras'],'shot_overrides':c.get('shot_overrides',[])},indent=2),encoding='utf-8')
        cmd += ['--project',str(project)]
    else:
        for key in ('cam_a','cam_b'):
            for path in c[key]:cmd += ['--'+key.replace('_','-'),path]
        if c.get('shot_overrides'):
            raise ValueError('Shot overrides require a camera project.')
    cmd += ['--audio',c['audio'],'--output-dir',c['output_dir'],'--report-json',str(report)]
    for key in ('mode','main_camera','main_share','seed','fps','cut_scale','crf','preset'):
        cmd += ['--'+key.replace('_','-'),str(c[key])]
    for key in ('a_center','b_center','main_hold','cutaway_hold','drop_hold','breakdown_hold'):
        cmd += ['--'+key.replace('_','-')]+list(map(str,c[key]))
    if c['output_name']: cmd += ['--output-name',c['output_name']]
    for key,flag in [('drops','--drop'),('breakdowns','--breakdown')]:
        for a,b in c[key]: cmd += [flag,f'{a},{b}']
    for t in c['activities']: cmd += ['--activity',str(t)]
    for item in c['overrides']:
        name=item['path']
        if item['offset'] is not None: cmd += ['--offset',f'{name}={item["offset"]}']
        if item['drift_ppm'] is not None: cmd += ['--drift-ppm',f'{name}={item["drift_ppm"]}']
    for key,flag,trigger in [('auto_sections','--no-auto-sections',False),('drift','--no-drift',False),('overwrite','--overwrite',True),('plan_only','--plan-only',True)]:
        if c[key] == trigger: cmd.append(flag)
    return cmd


class Studio:
    def __init__(self,state,default_folder,default_output=None,roots=None,remote=False,allowed_hosts=(),password=''):
        self.state=state;state.mkdir(parents=True,exist_ok=True)
        self.default_folder=default_folder
        self.default_output=default_output or default_folder/'Exports'
        self.remote=remote;self.allowed_hosts={h.strip().lower() for h in allowed_hosts if h.strip()}
        self.password=password
        self.setup_completed=any((state/'jobs').glob('*/job.json'))
        self.preferences_path=state/'preferences.json'
        self.dependency_cache=None
        try:
            preferences=json.loads(self.preferences_path.read_text(encoding='utf-8'))
            self.default_folder=Path(preferences.get('default_folder',str(default_folder))).expanduser().resolve()
            self.default_output=Path(preferences.get('default_output',str(self.default_output))).expanduser().resolve()
            self.setup_completed=bool(preferences.get('completed'))
        except (OSError,ValueError,TypeError):pass
        self.token=secrets.token_urlsafe(32)
        self.lock=threading.RLock();self.preview_lock=threading.Lock()
        self.jobs={};self.files={};self.file_ids={};self.active=None;self.stopping=False
        self.roots=list(roots) if roots else default_roots()
        if str(default_folder) not in self.roots: self.roots.insert(0,str(default_folder))
        for path in sorted((state/'jobs').glob('*/job.json'))[-30:]:
            try:
                job=json.loads(path.read_text(encoding='utf-8'))
                if job['status'] in ('queued','running'):
                    job.update(status='failed',error='The server stopped before this job finished.',stage='Interrupted')
                job['process']=None;job['logs']=job.get('logs',[])[-500:]
                self.jobs[job['id']]=job
            except (OSError,ValueError,KeyError): pass

    def register(self,path,kind=None):
        p=Path(path).resolve()
        if not p.is_file(): return None
        with self.lock:
            if str(p) not in self.file_ids:
                fid=secrets.token_urlsafe(24);self.files[fid]=p;self.file_ids[str(p)]=fid
            fid=self.file_ids[str(p)]
        if kind is None:
            kind='video' if p.suffix=='.mp4' else 'image' if p.suffix.lower() in ('.jpg','.png') else 'report' if p.suffix=='.json' else 'cut_list'
        return {'name':p.name,'kind':kind,'url':'/api/files/'+fid}

    def save(self,job):
        data={k:v for k,v in job.items() if k!='process'}
        target=Path(job['directory'])/'job.json'
        tmp=target.with_suffix('.tmp');tmp.write_text(json.dumps(data,indent=2),encoding='utf-8');tmp.replace(target)

    def snapshot(self,job):
        with self.lock:
            data={k:v for k,v in job.items() if k not in ('process','directory')}
            data['logs']=list(job['logs'])
            report_path=Path(job['directory'])/'report.json'
            try: report=json.loads(report_path.read_text(encoding='utf-8'))
            except (OSError,ValueError): report=None
            data['report']=report;artifacts=[]
            if report:
                outputs=report.get('outputs',{})
                for key,kind in [('video','video'),('cut_list','cut_list'),('report','report')]:
                    if outputs.get(key):
                        item=self.register(outputs[key],kind)
                        if item: artifacts.append(item)
                for clip in outputs.get('videos',[]):
                    item=self.register(clip['path'],'video')
                    if item:
                        item.update(source_path=clip['path'],start=clip.get('start'),end=clip.get('end'))
                        artifacts.append(item)
                for preview in outputs.get('previews',[]):
                    item=self.register(preview['path'],'image')
                    if item:
                        item.update(angle=preview.get('angle'),source_path=preview.get('source_path'))
                        artifacts.append(item)
            item=self.register(Path(job['directory'])/'render.log','log')
            if item: artifacts.append(item)
            data['artifacts']=artifacts
            return data

    def start(self,raw,kind='edit'):
        if not all(self.dependencies().values()):
            raise ValueError('The rendering tools are unavailable. Open Settings to check this installation.')
        if kind=='edit':config=validate_config(raw)
        else:
            import effects
            config=effects.validate_batch(raw) if kind=='highlights' else effects.validate_config(raw)
        
        with self.lock:
            if self.stopping:raise ValueError('Multicam Studio is closing. Reopen it before starting another job.')
            if self.active and self.jobs[self.active]['status'] in ('queued','running'):
                raise ValueError('A job is already running. Finish or cancel it first.')
            jid=dt.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+secrets.token_hex(3)
            directory=self.state/'jobs'/jid;directory.mkdir(parents=True)
            job={'id':jid,'kind':kind,'status':'queued','stage':'Preparing','progress':None,'logs':[],
                 'error':None,'config':config,'directory':str(directory),'process':None,
                 'created_at':dt.datetime.now().isoformat(),'cancel_requested':False}
            self.jobs[jid]=job;self.active=jid;self.save(job)
            threading.Thread(target=self.worker,args=(job,),daemon=True).start()
            return jid

    def worker(self,job):
        directory=Path(job['directory'])
        try:
            with self.lock:
                if job['cancel_requested']:
                    job.update(status='cancelled',stage='Cancelled');return
                if job.get('kind','edit')=='edit':
                    cmd=command_for(job['config'],directory/'report.json')
                else:
                    config_path=directory/'effects.json';config_path.write_text(json.dumps(job['config'],indent=2),encoding='utf-8')
                    cmd=worker_command('effects')+['--config',str(config_path),'--report-json',str(directory/'report.json')]
                proc=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                                      text=True,bufsize=1,cwd=APP,env=worker_environment(),
                                      **UTF8,**spawn_options())
                job.update(process=proc,status='running',stage='Synchronising' if job.get('kind','edit')=='edit' else 'Processing clip',progress=None)
            with (directory/'render.log').open('w',encoding='utf-8') as log:
                for line in proc.stdout:
                    line=line.rstrip();log.write(line+'\n');log.flush()
                    with self.lock:
                        job['logs'].append(line);job['logs']=job['logs'][-1500:]
                        match=re.search(r'Rendering (\d+)/(\d+):',line)
                        if match:
                            n,total=map(int,match.groups())
                            job.update(stage=f'Rendering shot {n} of {total}',progress=round((n-1)/total*95,1))
                        elif line.startswith('Batch clip '):
                            job.update(stage=line,progress=job.get('progress'))
                        elif 'Concatenating' in line:
                            job.update(stage='Assembling video and audio',progress=97)
                        elif line.startswith('duration_seconds='):
                            try:job['render_duration']=float(line.split('=',1)[1])
                            except ValueError:pass
                        elif line.startswith('progress_seconds='):
                            try:
                                seconds=float(line.split('=',1)[1]);length=job.get('render_duration',job['config'].get('end',0)-job['config'].get('start',0))
                                if length>0:job.update(progress=min(95,seconds/length*95))
                            except (TypeError,ValueError):pass
                        elif line.startswith('Syncing '): job.update(stage=line.rstrip(' …'),progress=None)
                        elif 'crop preview:' in line: job.update(stage='Preparing crop previews')
                code=proc.wait()
            with self.lock:
                if job['cancel_requested']:
                    job.update(status='cancelled',stage='Cancelled',progress=None)
                elif code==0:
                    job.update(status='completed',stage='Plan ready' if job['config'].get('plan_only') else 'Export ready',progress=100)
                else:
                    error=next((l.removeprefix('ERROR: ') for l in reversed(job['logs']) if l.startswith('ERROR:')),None)
                    job.update(status='failed',stage='Needs attention',error=error or '\n'.join(job['logs'][-8:]),progress=None)
        except Exception as exc:
            with self.lock:
                job.update(status='failed',stage='Needs attention',error=str(exc),progress=None)
                job['logs'].append(str(exc))
        finally:
            with self.lock:
                job['process']=None;job['finished_at']=dt.datetime.now().isoformat();self.save(job)
                if self.active==job['id']: self.active=None

    def cancel(self,jid):
        with self.lock:
            job=self.jobs.get(jid)
            if not job: raise ValueError('Job not found.')
            if job['status'] not in ('queued','running'): return
            job['cancel_requested']=True;job['stage']='Cancelling'
            proc=job.get('process')
        if proc and proc.poll() is None:
            signal_worker(proc,'interrupt')
            def stop_later():
                try: proc.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    signal_worker(proc,'terminate')
                    try: proc.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        signal_worker(proc,'kill')
            threading.Thread(target=stop_later,daemon=True).start()

    def dependencies(self):
        if self.dependency_cache is not None:
            return dict(self.dependency_cache)
        result={}
        for name in ('ffmpeg','ffprobe'):
            try:
                check=subprocess.run([name,'-version'],capture_output=True,timeout=10)
                result[name]=check.returncode==0
            except (OSError,subprocess.SubprocessError):result[name]=False
        for name in ('numpy','scipy'):
            try:__import__(name);result[name]=True
            except (ImportError,OSError):result[name]=False
        self.dependency_cache=result
        return dict(result)

    def setup_snapshot(self):
        dependencies=self.dependencies()
        return {'version':VERSION,'completed':self.setup_completed,
                'default_folder':str(self.default_folder),'default_output':str(self.default_output),
                'dependencies':dependencies,'can_render':all(dependencies.values()),
                'platform':platform.system(),'architecture':platform.machine(),
                'server_mode':self.remote}

    def save_setup(self, data):
        if not isinstance(data,dict):raise ValueError('Choose your setup folders.')
        folder=resolved(data.get('default_folder'));output=resolved(data.get('default_output'))
        if not folder.is_dir():raise ValueError('The recordings folder is unavailable. Check the drive is connected.')
        writable_folder(output)
        if not all(self.dependencies().values()):
            raise ValueError('The rendering tools are unavailable. Repair or reinstall the app before completing setup.')
        preferences={'completed':True,'version':VERSION,'default_folder':str(folder),'default_output':str(output)}
        with self.lock:
            temporary=self.preferences_path.with_suffix('.tmp')
            temporary.write_text(json.dumps(preferences,indent=2),encoding='utf-8');temporary.replace(self.preferences_path)
            self.default_folder=folder;self.default_output=output;self.setup_completed=True
            if str(folder) not in self.roots:self.roots.insert(0,str(folder))
        return self.setup_snapshot()

    def diagnostics(self):
        with self.lock:
            statuses=[{'kind':j.get('kind','edit'),'status':j['status']} for j in self.jobs.values()]
        return {'app':'Multicam Studio','version':VERSION,'platform':platform.platform(),
                'architecture':platform.machine(),'python':platform.python_version(),
                'bundled_app':bool(getattr(sys,'frozen',False)),'server_mode':self.remote,'dependencies':self.dependencies(),
                'setup_completed':self.setup_completed,'job_count':len(statuses),'jobs':statuses,
                'working_disk_free_gb':round(shutil.disk_usage(self.state).free/1e9,2)}


class Handler(BaseHTTPRequestHandler):
    server_version='MulticamStudio/'+VERSION
    protocol_version='HTTP/1.1'
    timeout=30
    @property
    def studio(self): return self.server.studio
    def handle(self):
        # Browsers routinely abandon buffered media requests when seeking or closing a tab.
        # This also covers a reset while HTTP/1.1 waits for the next request line.
        try:super().handle()
        except DISCONNECTS:self.close_connection=True
    def handle_one_request(self):
        self.response_started=False
        return super().handle_one_request()
    def send_response(self,code,message=None):
        self.response_started=True
        return super().send_response(code,message)
    def log_message(self,fmt,*args):
        if fmt.startswith('Request timed out:'):return
        if args and len(args)>1 and str(args[1]).isdigit() and int(args[1])<400:return
        super().log_message(fmt,*args)
    def error_response(self,status,error):
        if self.response_started:
            self.close_connection=True
            return
        self.json_response(status,{'error':str(error)})
    def headers_common(self):
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Cache-Control','no-store')
        self.send_header('Referrer-Policy','no-referrer')
        self.send_header('X-Frame-Options','DENY')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
    def json_response(self,status,data):
        body=json.dumps(data).encode();self.send_response(status);self.headers_common()
        if status >= 400:
            self.close_connection=True
            self.send_header('Connection','close')
        self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        if self.command!='HEAD':self.wfile.write(body)
    def authorised(self):
        password=self.studio.password
        if not password:return True
        auth=self.headers.get('Authorization','')
        if auth[:6].lower()=='basic ':
            try:
                supplied=base64.b64decode(auth[6:].strip(),validate=True).decode('utf-8').partition(':')[2]
                if secrets.compare_digest(supplied.encode(),password.encode()):return True
            except (ValueError,UnicodeDecodeError):pass
        body=json.dumps({'error':'Sign in to use Multicam Studio.'}).encode()
        self.send_response(401);self.headers_common()
        self.send_header('WWW-Authenticate','Basic realm="Multicam Studio", charset="UTF-8"')
        self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)))
        self.send_header('Connection','close');self.close_connection=True;self.end_headers()
        if self.command!='HEAD':self.wfile.write(body)
        return False
    def allowed(self,token=True):
        host=self.headers.get('Host','').strip().lower()
        origin=self.headers.get('Origin')
        if self.studio.remote:
            # Server mode (Docker): any address that reaches us, unless restricted,
            # but browser requests must come from this same site.
            name=host.rsplit(':',1)[0] if host.count(':')==1 else host
            if not host or (self.studio.allowed_hosts and host not in self.studio.allowed_hosts
                            and name.strip('[]') not in self.studio.allowed_hosts):
                self.json_response(403,{'error':'This host name is not allowed. Add it to MULTICAM_ALLOWED_HOSTS.'});return False
            sites={host}|{h.strip().lower() for h in self.headers.get('X-Forwarded-Host','').split(',') if h.strip()}
            if origin and origin.lower() not in {f'{scheme}://{h}' for h in sites for scheme in ('http','https')}:
                self.json_response(403,{'error':'Request origin is not allowed.'});return False
            if not self.authorised():return False
        else:
            port=self.server.server_port
            hosts={f'127.0.0.1:{port}',f'localhost:{port}'}
            if host not in hosts:
                self.json_response(403,{'error':'This service accepts local requests only.'});return False
            if origin and origin not in {f'http://{h}' for h in hosts}:
                self.json_response(403,{'error':'Request origin is not allowed.'});return False
        if token and not secrets.compare_digest(self.headers.get('X-Multicam-Token',''),self.studio.token):
            self.json_response(403,{'error':'Refresh this page to reconnect to the local server.'});return False
        return True
    def read_json(self):
        length=int(self.headers.get('Content-Length','0'))
        if length<=0 or length>2*1024*1024: raise ValueError('Invalid request size.')
        if self.headers.get('Content-Type','').split(';')[0]!='application/json':
            raise ValueError('Expected JSON settings.')
        return json.loads(self.rfile.read(length))
    def do_HEAD(self):
        self.do_GET()
    def do_GET(self):
        u=urlparse(self.path);query=parse_qs(u.query)
        if u.path=='/api/health':
            # Unauthenticated liveness check, also used by the Docker healthcheck.
            return self.json_response(200,{'app_id':APP_ID,'version':VERSION,'instance_id':self.studio.token[:16]})
        if not self.allowed(token=u.path.startswith('/api/') and not u.path.startswith('/api/files/') and u.path!='/api/health'): return
        try:
            if u.path=='/api/health':
                return self.json_response(200,{'app_id':APP_ID,'version':VERSION,'instance_id':self.studio.token[:16]})
            if u.path=='/favicon.ico':
                self.send_response(204);self.send_header('Content-Length','0');self.end_headers();return
            if u.path=='/favicon.svg':
                return self.bytes_response(b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect x="6" y="10" width="38" height="25" rx="4" fill="none" stroke="#e6b774" stroke-width="4"/><rect x="35" y="22" width="20" height="34" rx="4" fill="#11170f" stroke="#8dcccf" stroke-width="4"/></svg>','image/svg+xml')
            if u.path in ('/','/index.html'):
                body=(APP/'web/index.html').read_text(encoding='utf-8').replace('__MULTICAM_TOKEN__',json.dumps(self.studio.token)).encode()
                return self.bytes_response(body,'text/html; charset=utf-8')
            if u.path in ('/app.js','/app.css','/static/app.js','/static/app.css','/static/studio.css'):
                p=APP/'web'/u.path.rsplit('/',1)[-1]
                return self.bytes_response(p.read_bytes(),'text/javascript' if p.suffix=='.js' else 'text/css')
            if u.path=='/api/config':
                setup=self.studio.setup_snapshot()
                return self.json_response(200,{**setup,'setup_completed':setup['completed'],'roots':self.studio.roots})
            if u.path=='/api/setup':
                self.studio.dependency_cache=None
                return self.json_response(200,self.studio.setup_snapshot())
            if u.path=='/api/diagnostics':return self.json_response(200,self.studio.diagnostics())
            if u.path=='/api/browse':
                p=resolved(query.get('path',[str(self.studio.default_folder)])[0])
                requested=p
                while not p.is_dir() and p!=p.parent:p=p.parent
                if not p.is_dir():raise ValueError('That folder is unavailable. Check the drive is connected.')
                kind=query.get('kind',['video'])[0];entries=[]
                for item in p.iterdir():
                    if item.name.startswith('.'): continue
                    is_dir=item.is_dir()
                    if not is_dir and (kind=='folder' or item.suffix.lower() not in (AUDIO_EXTS if kind=='audio' else VIDEO_EXTS)): continue
                    try: entries.append({'name':item.name,'path':str(item),'is_dir':is_dir,'size':0 if is_dir else item.stat().st_size})
                    except OSError: continue
                entries.sort(key=lambda e:(not e['is_dir'],e['name'].lower()))
                return self.json_response(200,{'path':str(p),'parent':str(p.parent),'roots':self.studio.roots,'entries':entries,'requested_path':str(requested),'fallback':p!=requested})
            if u.path=='/api/jobs':
                with self.studio.lock: jobs=[self.studio.snapshot(j) for j in list(reversed(list(self.studio.jobs.values())))[:30]]
                return self.json_response(200,{'jobs':jobs})
            if u.path.startswith('/api/jobs/'):
                jid=u.path.split('/')[3]
                if jid not in self.studio.jobs: return self.json_response(404,{'error':'Job not found.'})
                return self.json_response(200,self.studio.snapshot(self.studio.jobs[jid]))
            if u.path.startswith('/api/files/'):
                fid=u.path.split('/')[-1]
                path=self.studio.files.get(fid)
                if not path: return self.json_response(404,{'error':'File not found. Refresh the job results.'})
                return self.file_response(path)
            return self.json_response(404,{'error':'Not found.'})
        except DISCONNECTS:self.close_connection=True
        except FileNotFoundError:self.error_response(404,'File not found. Check the drive is connected and refresh the results.')
        except PermissionError:self.error_response(403,'Cannot access this file or folder. Check its permissions.')
        except (OSError,ValueError,KeyError) as exc:self.error_response(400,exc)
        except Exception:
            traceback.print_exc();self.error_response(500,'An unexpected error occurred. Open Settings for diagnostics.')
    def bytes_response(self,body,mime):
        self.send_response(200);self.headers_common();self.send_header('Content-Type',mime)
        self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def file_response(self,path):
        # Open before sending headers, so moved/deleted media returns a proper 404.
        with path.open('rb') as f:
            size=os.fstat(f.fileno()).st_size;start=0;end=size-1;status=200
            range_header=self.headers.get('Range')
            if range_header:
                match=re.fullmatch(r'bytes=(\d*)-(\d*)',range_header.strip())
                valid=bool(match and any(match.groups()))
                if valid:
                    a,b=match.groups()
                    try:
                        if a:start=int(a);end=min(int(b),size-1) if b else size-1
                        else:start=max(0,size-int(b))
                        valid=size>0 and start<size and end>=start
                    except ValueError:valid=False
                if not valid:
                    self.send_response(416);self.headers_common()
                    self.send_header('Content-Range',f'bytes */{size}')
                    self.send_header('Content-Length','0');self.end_headers();return
                status=206
            self.send_response(status);self.headers_common()
            self.send_header('Content-Type',mimetypes.guess_type(path.name)[0] or 'application/octet-stream')
            self.send_header('Accept-Ranges','bytes');self.send_header('Content-Length',str(max(0,end-start+1)))
            self.send_header('Content-Disposition',"inline; filename*=UTF-8''"+quote(path.name))
            if status==206:self.send_header('Content-Range',f'bytes {start}-{end}/{size}')
            self.end_headers()
            if self.command=='HEAD':return
            f.seek(start);remaining=end-start+1
            while remaining>0:
                data=f.read(min(1024*1024,remaining))
                if not data:
                    self.close_connection=True
                    return
                self.wfile.write(data);remaining-=len(data)
    def do_POST(self):
        if not self.allowed():return
        u=urlparse(self.path)
        try:
            if u.path=='/api/upload':return self.upload(parse_qs(u.query))
            data=self.read_json()
            if not isinstance(data,dict):raise ValueError('Expected settings as a JSON object.')
            if u.path=='/api/setup':return self.json_response(200,self.studio.save_setup(data))
            if u.path=='/api/shutdown':
                if self.studio.remote:
                    return self.json_response(409,{'error':'This studio runs as a server. Stop it from Docker or your container manager.'})
                with self.studio.lock:
                    if self.studio.active:
                        return self.json_response(409,{'error':'A job is still running. Finish or cancel it before quitting.'})
                    self.studio.stopping=True
                self.json_response(200,{'ok':True})
                threading.Thread(target=self.server.shutdown,daemon=True).start()
                return
            if u.path=='/api/folders':
                parent=resolved(data.get('parent'));name=str(data.get('name','')).strip()
                if not parent.is_dir():raise ValueError('Choose an existing parent folder.')
                if not name or name in ('.','..') or any(c in name for c in '/\\\x00') or len(name)>200:
                    raise ValueError('Use a folder name without slashes, up to 200 characters.')
                target=parent/name
                target.mkdir()
                return self.json_response(201,{'path':str(target),'name':name})
            if u.path=='/api/jobs':return self.json_response(201,{'id':self.studio.start(data)})
            if u.path=='/api/highlights/export':
                return self.json_response(201,{'id':self.studio.start(data,'highlights')})
            if u.path in ('/api/clips','/api/effects'):
                if u.path=='/api/clips':
                    data={**data,'fade_in':0,'fade_out':0,'bounce':0,'style':'none','brightness':0,'contrast':1,'saturation':1,'vignette':False,'preview':False}
                return self.json_response(201,{'id':self.studio.start(data,'clip' if u.path=='/api/clips' else 'effects')})
            if u.path=='/api/source-frame':return self.source_frame(data)
            if u.path=='/api/waveform':return self.waveform(data)
            if re.fullmatch(r'/api/jobs/[^/]+/cancel',u.path):
                self.studio.cancel(u.path.split('/')[3]);return self.json_response(200,{'ok':True})
            if u.path=='/api/probe':
                paths=data.get('paths',[])
                if not isinstance(paths,list) or len(paths)>200:raise ValueError('Too many files.')
                files=[]
                for value in paths:
                    p=resolved(value)
                    item={'path':str(p),'name':p.name}
                    try:
                        if not p.is_file() or p.suffix.lower() not in VIDEO_EXTS|AUDIO_EXTS:raise ValueError('Choose a MOV, MP4 or WAV file.')
                        result=subprocess.run(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(p)],capture_output=True,text=True,**UTF8,timeout=20)
                        if result.returncode:raise ValueError(result.stderr[-1000:])
                        meta=json.loads(result.stdout);v=next((s for s in meta['streams'] if s['codec_type']=='video'),{})
                        width,height=v.get('width'),v.get('height')
                        for side in v.get('side_data_list',[]):
                            if abs(int(side.get('rotation',0)))%180==90:width,height=height,width
                        item.update(duration=float(meta['format'].get('duration',0)),width=width,height=height,
                                    has_audio=any(s['codec_type']=='audio' for s in meta['streams']))
                    except Exception as exc:item['error']=str(exc)
                    files.append(item)
                return self.json_response(200,{'files':files})
            if u.path=='/api/preview':return self.preview(data)
            self.json_response(404,{'error':'Not found.'})
        except DISCONNECTS:self.close_connection=True
        except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as exc:self.error_response(400,exc)
        except Exception:
            traceback.print_exc();self.error_response(500,'An unexpected error occurred. Open Settings for diagnostics.')
    def upload(self,query):
        name=query.get('name',[''])[0]
        if Path(name).name!=name or Path(name).suffix.lower() not in VIDEO_EXTS|AUDIO_EXTS or len(name)>220:
            raise ValueError('Upload a MOV, MP4 or WAV file.')
        size=int(self.headers.get('Content-Length','0'))
        if size<=0:raise ValueError('This file is empty.')
        if size>shutil.disk_usage(self.studio.state).free-128*1024*1024:raise ValueError('Not enough disk space for this upload. Use Browse to select it without copying.')
        folder=self.studio.state/'uploads'/secrets.token_hex(8);folder.mkdir(parents=True)
        target=folder/name;partial=folder/(name+'.uploading')
        try:
            with partial.open('wb') as f:
                left=size
                while left:
                    chunk=self.rfile.read(min(left,1024*1024))
                    if not chunk:raise ValueError('Upload interrupted.')
                    f.write(chunk);left-=len(chunk)
            partial.replace(target)
        except Exception:
            partial.unlink(missing_ok=True);raise
        self.json_response(201,{'path':str(target),'name':name,'size':size})
    def preview(self,data):
        p=resolved(data.get('path'))
        if not p.is_file() or p.suffix.lower() not in VIDEO_EXTS:raise ValueError('Choose a camera recording first.')
        mode=data.get('mode','horizontal');angle=data.get('angle')
        if mode not in ('horizontal','vertical') or not isinstance(angle,str):raise ValueError('Invalid preview mode or angle.')
        centres=[]
        for key,default in [('a_center',[.5,.5]),('b_center',[.5,.72])]:
            pair=data.get(key,default)
            if not isinstance(pair,list) or len(pair)!=2:raise ValueError('Choose X and Y for the crop.')
            centres.append([finite(v,key,0,1) for v in pair])
        at=finite(data.get('time',3),'Preview time',0)
        import multicam_edit as editor
        pw,ph=(540,960) if mode=='vertical' else (960,540)
        if data.get('framing') is not None:
            framing=validate_framing(data['framing'])
            filters=editor.framing_filter(framing,mode)+f',scale={pw}:{ph}'
        else:
            filters=editor.crop_filter(angle,centres[1],mode,centres[0])+f',scale={pw}:{ph}'
        folder=self.studio.state/'previews';folder.mkdir(exist_ok=True)
        target=folder/(secrets.token_hex(12)+'.jpg')
        with self.studio.preview_lock:
            result=subprocess.run(['ffmpeg','-v','error','-nostdin','-y','-ss',str(at),'-i',str(p),'-map','0:v:0','-an','-vf',filters,'-frames:v','1','-update','1',str(target)],capture_output=True,text=True,**UTF8,timeout=60)
        if result.returncode or not target.exists():raise ValueError(result.stderr[-1000:] or 'No frame at that time. Try an earlier preview time.')
        return self.json_response(200,self.studio.register(target,'image'))

    def source_frame(self,data):
        path=resolved(data.get('path'))
        if not path.is_file() or path.suffix.lower() not in VIDEO_EXTS:raise ValueError('Choose a camera recording.')
        at=finite(data.get('time',3),'Preview time',0)
        folder=self.studio.state/'previews';folder.mkdir(exist_ok=True)
        target=folder/(secrets.token_hex(12)+'.jpg')
        result=subprocess.run(['ffmpeg','-v','error','-nostdin','-y','-ss',str(at),'-i',str(path),'-map','0:v:0','-an','-vf',"scale=1280:1280:force_original_aspect_ratio=decrease",'-frames:v','1','-update','1',str(target)],capture_output=True,text=True,**UTF8,timeout=60)
        if result.returncode or not target.exists():raise ValueError(result.stderr[-1000:] or 'No frame at that time. Try an earlier time.')
        info=json.loads(subprocess.run(['ffprobe','-v','error','-show_streams','-of','json',str(target)],capture_output=True,text=True,**UTF8,check=True).stdout)['streams'][0]
        item=self.studio.register(target,'image');item.update(width=info['width'],height=info['height'])
        return self.json_response(200,item)

    def waveform(self,data):
        path=resolved(data.get('path'))
        if not path.is_file() or path.suffix.lower() not in VIDEO_EXTS|AUDIO_EXTS:raise ValueError('Choose a WAV bounce or rendered video.')
        folder=self.studio.state/'waveforms';folder.mkdir(exist_ok=True)
        stat=path.stat();key=hashlib.sha256(f'v4:{path}:{stat.st_size}:{stat.st_mtime_ns}'.encode()).hexdigest()
        cached=folder/(key+'.json')
        if cached.exists():result=json.loads(cached.read_text(encoding='utf-8'))
        else:
            import numpy as np
            pcm=folder/(key+'-'+secrets.token_hex(4)+'.f32');samples=None
            try:
                proc=subprocess.run(['ffmpeg','-v','error','-nostdin','-y','-i',str(path),'-map','0:a:0','-vn','-ac','1','-ar','8000','-c:a','pcm_f32le','-f','f32le',str(pcm)],capture_output=True,text=True,**UTF8,timeout=300)
                if proc.returncode or not pcm.exists() or pcm.stat().st_size<4:raise ValueError(proc.stderr[-1000:] or 'No audio available.')
                samples=np.memmap(pcm,dtype='<f4',mode='r');duration=len(samples)/8000
                # Use the movie timeline, excluding decoded AAC padding beyond it.
                # Any short audio tail is represented as silence on the waveform.
                if path.suffix.lower() in VIDEO_EXTS:
                    meta=json.loads(subprocess.run(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(path)],capture_output=True,text=True,**UTF8,check=True).stdout)
                    video=next((v for v in meta['streams'] if v['codec_type']=='video'),{})
                    declared=video.get('duration',meta.get('format',{}).get('duration'))
                    if declared not in (None,'N/A') and float(declared)>0:duration=float(declared)
                sample_count=max(1,round(duration*8000))
                count=min(5000,sample_count);edges=np.linspace(0,sample_count,count+1,dtype=int)
                values=np.array([np.sqrt(np.mean(np.nan_to_num(np.asarray(samples[a:min(b,len(samples))]))**2)) if a<len(samples) else 0 for a,b in zip(edges,edges[1:])])
                maximum=float(np.max(values))
                peaks=(values/max(maximum,1e-9)).clip(0,1)
                result={'duration':duration,'sample_rate':8000,'peaks':[round(float(x),5) for x in peaks],'maximum':maximum}
                temporary=cached.with_name(key+'-'+secrets.token_hex(4)+'.tmp');temporary.write_text(json.dumps(result),encoding='utf-8');temporary.replace(cached)
            finally:
                # Windows cannot delete a file that is still memory-mapped.
                samples=None
                try:pcm.unlink(missing_ok=True)
                except OSError:pass
        from highlights import plan_clips
        result['energetic']=plan_clips(result['peaks'],result['duration'],data.get('target_seconds',30),result['maximum'])
        result['target_seconds']=float(data.get('target_seconds',30))
        result['audio_url']=self.studio.register(path,'audio')['url']
        return self.json_response(200,result)


class InstanceLock:
    """One server per working folder. Never kill a process just because a port is busy."""
    def __init__(self,state):
        state.mkdir(parents=True,exist_ok=True)
        self.path=state/'server.lock'
        self.file=self.path.open('a+',encoding='utf-8')
        # Windows locks block reads of the locked bytes, so lock a separate file
        # there and keep server.lock readable by a second copy.
        self.guard=(state/'server.lock.guard').open('a+') if WINDOWS else self.file
        self.owned=False

    def acquire(self):
        try:
            if WINDOWS:
                self.guard.seek(0);msvcrt.locking(self.guard.fileno(),msvcrt.LK_NBLCK,1)
            else:fcntl.flock(self.file,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except OSError:return False
        self.owned=True
        return True

    def publish(self,url,instance_id):
        self.file.seek(0);self.file.truncate()
        json.dump({'pid':os.getpid(),'url':url,'instance_id':instance_id},self.file)
        self.file.flush();os.fsync(self.file.fileno())

    def running_url(self):
        for _ in range(30):
            try:
                self.file.seek(0);data=json.load(self.file)
                url=data['url'];parsed=urlparse(url)
                if parsed.scheme!='http' or parsed.hostname not in ('127.0.0.1','localhost') or not parsed.port:
                    return None
                with urllib.request.urlopen(url+'/api/health',timeout=1) as response:
                    live=json.load(response)
                if live.get('app_id')==APP_ID and live.get('instance_id')==data.get('instance_id'):
                    return url
            except (OSError,ValueError,KeyError):pass
            time.sleep(.1)
        return None

    def close(self):
        if self.owned:
            self.file.seek(0);self.file.truncate();self.file.flush()
            if WINDOWS:
                self.guard.seek(0);msvcrt.locking(self.guard.fileno(),msvcrt.LK_UNLCK,1)
            else:fcntl.flock(self.file,fcntl.LOCK_UN)
        self.file.close()
        if self.guard is not self.file:self.guard.close()


def request_stop():
    """Native app signal handler: stop accepting work, then let main clean up workers."""
    server=_RUNNING_SERVER
    if server:
        with server.studio.lock:server.studio.stopping=True
        threading.Thread(target=server.shutdown,daemon=True).start()


class StudioHTTPServer(ThreadingHTTPServer):
    # On Windows SO_REUSEADDR lets two servers share a port; fail and pick another instead.
    allow_reuse_address=not WINDOWS


def main():
    global _RUNNING_SERVER
    env=os.environ.get
    parser=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--host',default=env('MULTICAM_HOST','127.0.0.1'),
                        help='127.0.0.1 (default) for this computer only; 0.0.0.0 to serve other machines, as in Docker')
    parser.add_argument('--port',type=int,default=int(env('MULTICAM_PORT','8765')))
    parser.add_argument('--open',action='store_true')
    parser.add_argument('--default-folder',type=Path,default=Path(env('MULTICAM_DEFAULT_FOLDER',str(default_media_folder()))))
    parser.add_argument('--default-output',type=Path,default=Path(env('MULTICAM_DEFAULT_OUTPUT')) if env('MULTICAM_DEFAULT_OUTPUT') else None,
                        help='Initial export folder (default: DEFAULT_FOLDER/Exports)')
    parser.add_argument('--state-dir',type=Path,default=Path(env('MULTICAM_STATE_DIR',str(APP/'.multicam-studio'))))
    parser.add_argument('--root',action='append',default=[p for p in env('MULTICAM_ROOTS','').split(os.pathsep) if p],
                        help='Folder shortcut in the file browser; repeat for several (default: home and drives)')
    parser.add_argument('--allowed-host',action='append',default=[h for h in env('MULTICAM_ALLOWED_HOSTS','').split(',') if h.strip()],
                        help='Server mode: only accept these host names (repeatable)')
    args=parser.parse_args()
    password=env('MULTICAM_PASSWORD','')
    if not 0<=args.port<=65535:parser.error('Port must be between 0 and 65535.')
    remote=args.host not in LOOPBACK
    folder=args.default_folder.expanduser().resolve()
    if folder==default_media_folder():folder.mkdir(exist_ok=True)
    if not folder.is_dir():parser.error('The default folder is not available. Reconnect the drive or choose another folder.')
    roots=[str(Path(p).expanduser().resolve()) for p in args.root]
    output=args.default_output.expanduser().resolve() if args.default_output else None
    state=args.state_dir.expanduser().resolve()
    guard=InstanceLock(state)
    if not guard.acquire():
        url=guard.running_url();guard.close()
        if url:
            print(f'Multicam Studio is already running: {url}',flush=True)
            if args.open:webbrowser.open(url)
            return
        raise RuntimeError('Another copy of Multicam Studio is starting or not responding. Wait a moment and try again.')
    server=None
    studio=None
    previous_handlers={}
    try:
        studio=Studio(state,folder,output,roots,remote,args.allowed_host,password)
        try:server=StudioHTTPServer((args.host,args.port),Handler)
        except OSError as exc:
            if remote or exc.errno not in (errno.EADDRINUSE,getattr(errno,'WSAEADDRINUSE',10048)):raise
            # An unrelated service can occupy the default port. Ask the system for a free one.
            server=StudioHTTPServer((args.host,0),Handler)
        server.daemon_threads=True;server.studio=studio
        _RUNNING_SERVER=server
        url=f'http://127.0.0.1:{server.server_port}'
        guard.publish(url,studio.token[:16])
        if remote:
            print(f'Multicam Studio {VERSION}: serving http://{args.host}:{server.server_port}',flush=True)
            if not password:
                print('WARNING: anyone who can reach this port can use the studio and browse its folders. '
                      'Set MULTICAM_PASSWORD to require a password.',flush=True)
        else:
            print(f'Multicam Studio {VERSION}: {url}\nFiles stay on this computer.',flush=True)
        if threading.current_thread() is threading.main_thread():
            def stop_server(signum,frame):
                request_stop()
            for sig in (signal.SIGINT,signal.SIGTERM):
                previous_handlers[sig]=signal.signal(sig,stop_server)
        if args.open:webbrowser.open(url)
        server.serve_forever(poll_interval=.2)
    finally:
        if studio and studio.active:
            job=studio.jobs[studio.active];proc=job.get('process')
            studio.cancel(studio.active)
            if proc:
                try:proc.wait(timeout=13)
                except subprocess.TimeoutExpired:signal_worker(proc,'kill')
            # The worker normally commits its cancelled result immediately after exit.
            deadline=time.monotonic()+2
            while studio.active and time.monotonic()<deadline:time.sleep(.05)
        if server:server.server_close()
        _RUNNING_SERVER=None
        for sig,handler in previous_handlers.items():signal.signal(sig,handler)
        guard.close()


if __name__=='__main__':main()
