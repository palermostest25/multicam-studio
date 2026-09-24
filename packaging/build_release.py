#!/usr/bin/env python3
"""Build a relocatable macOS app, ZIP, DMG and matching FFmpeg source archive.

Run with a Python environment containing packaging/build-requirements.txt.
Example: python packaging/build_release.py --work-dir /large/disk/multicam-build
For Intel, run this same script with an x86_64 Python environment on Intel/Rosetta.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = '1.2.0'


def run(args, **kwargs):
    print('+', ' '.join(map(str,args)), flush=True)
    subprocess.run(list(map(str,args)), check=True, **kwargs)


def is_notice_path(path):
    parts=Path(path).parts
    if any(part.startswith('._') or part == '__pycache__' or
           part.lower().endswith('.dsym') for part in parts):
        return False
    # Common exact filenames and license directories, plus named license
    # variants such as COPYING.GPLv2, LICENSE-MIT, and LICENSE.APACHE2.
    pattern = (r'(?:licen[cs]es?|copying|notices?)(?:[-.]'
               r'(?:txt|text|md|rst|html|gplv?[0-9.]*|lgplv?[0-9.]*|'
               r'mit|bsd[0-9-]*|apache[0-9.-]*|lesser|exception))?')
    return any(re.fullmatch(pattern, part, re.IGNORECASE) for part in parts)


def collect_notices(work):
    directory = ROOT/'packaging/notices'
    directory.mkdir(parents=True, exist_ok=True)
    versions={}
    for name in ['numpy','scipy','pyinstaller','pyinstaller-hooks-contrib','pyobjc-core','pyobjc-framework-Cocoa','altgraph','macholib','packaging','setuptools']:
        dist=importlib.metadata.distribution(name)
        versions[name]=dist.version
        target=directory/name;target.mkdir(exist_ok=True)
        # Only actual license names/directories qualify. Test modules named
        # copying.cpython-*.so and their debug bundles are not notices.
        for stale in target.iterdir():
            if '.dSYM__' in stale.name or stale.name.startswith('._'):
                if stale.is_file() or stale.is_symlink():
                    stale.unlink()
        for item in dist.files or []:
            if is_notice_path(item):
                source=Path(dist.locate_file(item))
                if source.is_file():
                    content=source.read_bytes()
                    if b'\x00' in content:
                        continue  # Never place native binaries in notices.
                    relative='__'.join(item.parts)
                    shutil.copy2(source,target/relative)
        # Some distributions store the complete license in metadata only.
        if not any(target.iterdir()):
            (target/'METADATA.txt').write_text(dist.read_text('METADATA') or '',encoding='utf-8')
    python_license=Path(sys.base_prefix)/'lib'/f'python{sys.version_info.major}.{sys.version_info.minor}'/'LICENSE.txt'
    if python_license.is_file():shutil.copy2(python_license,directory/'Python-LICENSE.txt')
    for source in work.glob('ffmpeg-build-*/COPYING*'):
        if source.is_file():shutil.copy2(source,directory/('FFmpeg-'+source.name))
    for source in work.glob('x264-*/COPYING'):
        shutil.copy2(source,directory/'x264-COPYING.txt')
        break
    (directory/'VERSIONS.json').write_text(json.dumps({'python':sys.version,**versions},indent=2))
    (directory/'THIRD-PARTY-NOTICES.txt').write_text('''Multicam Studio bundles independent runtime components.

Python: Python Software Foundation license; see Python-LICENSE.txt.
NumPy and SciPy: BSD licenses and bundled-library notices in their directories.
PyObjC: MIT license; see pyobjc-core and pyobjc-framework-Cocoa directories.
PyInstaller bootloader: GPL with a distribution exception permitting bundled apps;
see the included PyInstaller license and exception text.
FFmpeg 9.0.1 with libx264: GPL version 2 or later, because GPL components are enabled.
x264 source revision b35605ace3ddf7c1a5d67a2eb553f034aef41d55: GPL version 2 or later.

FFmpeg and x264 are separate executables invoked as subprocesses. The exact source
archives and build instructions are distributed with this release in the matching
Multicam-Studio-1.2.0-Sources.zip. Redistribute that archive alongside the binaries.
It also contains the Multicam Studio source files used for this build.

Official sources: https://ffmpeg.org/ and https://code.videolan.org/videolan/x264
Build source checksums are included in the source archive. Third-party notices do
not change the copyright or license of the original application source.
''')
    return versions


def audit(app):
    forbidden=[];minimum=(0,0);macho=[]
    magics={b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'}
    for path in app.rglob('*'):
        if any(part.startswith('._') for part in path.relative_to(app).parts):
            raise RuntimeError(f'AppleDouble metadata must not be packaged: {path}')
        if not path.is_file() or path.is_symlink():continue
        try:
            with path.open('rb') as stream:magic=stream.read(4)
        except OSError:continue
        if magic not in magics:continue
        macho.append(path)
        result=subprocess.check_output(['/usr/bin/otool','-L',str(path)],text=True)
        for line in result.splitlines()[1:]:
            dep=line.strip().split(' (')[0]
            if dep.startswith('/') and not dep.startswith(('/usr/lib/','/System/Library/')):
                forbidden.append(f'{path.relative_to(app)} -> {dep}')
        build=subprocess.check_output(['/usr/bin/vtool','-show-build',str(path)],text=True,stderr=subprocess.DEVNULL)
        for item in re.findall(r'\bminos\s+(\d+(?:\.\d+)+)',build):
            minimum=max(minimum,tuple(map(int,item.split('.')[:2])))
    if forbidden:raise RuntimeError('Unrelocated build-machine dependencies:\n'+'\n'.join(forbidden))
    return {'macho_files':len(macho),'binary_minimum_macos':'.'.join(map(str,minimum)),'external_dependencies':[]}


def sources_zip(destination,work):
    with zipfile.ZipFile(destination,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
        for path in (work/'sources').iterdir():
            if path.is_file() and not path.name.startswith('._'):archive.write(path,'third-party/'+path.name)
        for pattern in ['desktop.py','server.py','multicam_edit.py','effects.py','highlights.py','requirements.txt','README.md','CHANGELOG.md','docs/*.md','tests/*.py','tests/*.cjs','Start Multicam Studio.command','packaging/*.py','packaging/*.sh','packaging/*.spec','packaging/*.txt','packaging/*.plist','packaging/*.md','packaging/*.icns','web/*']:
            for path in ROOT.glob(pattern):
                if path.is_file() and not path.name.startswith('._'):archive.write(path,'multicam-studio/'+str(path.relative_to(ROOT)))
        for path in (ROOT/'packaging/notices').rglob('*'):
            if path.is_file() and not any(part.startswith('._') for part in path.relative_to(ROOT).parts):
                archive.write(path,'multicam-studio/'+str(path.relative_to(ROOT)))
        archive.writestr('BUILD.txt','Build FFmpeg/x264 from the provided archives with multicam-studio/packaging/build_ffmpeg.sh. See multicam-studio/packaging/RELEASE.md for the full app recipe. Sources are unmodified upstream archives; the configure commands in build_ffmpeg.sh are the complete build changes.\n')


def bundle_workspace(work, arch, requested=None):
    """Use a Mac filesystem for signed bundles (exFAT cannot preserve symlinks)."""
    if requested:
        destination=requested.expanduser().resolve()
        destination.mkdir(parents=True,exist_ok=True)
    else:
        destination=work
    volume=destination
    while not os.path.ismount(volume): volume=volume.parent
    result=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist',str(volume)]))
    if result.get('FilesystemType','').lower() in ('apfs','hfs'):
        return destination
    if requested:
        raise RuntimeError('--bundle-dir must be on an APFS or Mac OS Extended volume.')
    # Keep large files on the requested build disk while preserving Mac metadata.
    image=work/f'bundle-{arch}.sparseimage'
    mountpoint=Path(tempfile.gettempdir())/('multicam-build-'+hashlib.sha256(str(image).encode()).hexdigest()[:12])
    mountpoint.mkdir(exist_ok=True)
    if not image.exists():
        run(['/usr/bin/hdiutil','create','-size','3g','-type','SPARSE','-fs','APFS',
             '-volname',f'Multicam Build {arch}',image])
    mounted=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']))
    for item in mounted.get('images',[]):
        if Path(item.get('image-path','')).resolve()==image:
            for entity in item.get('system-entities',[]):
                if entity.get('mount-point'): return Path(entity['mount-point'])
    run(['/usr/bin/hdiutil','attach','-nobrowse','-mountpoint',mountpoint,image])
    return mountpoint


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir',type=Path,required=True)
    parser.add_argument('--skip-ffmpeg',action='store_true')
    parser.add_argument('--bundle-dir',type=Path,help='Optional APFS/HFS+ directory for signed app and DMG staging')
    parser.add_argument('--skip-dmg',action='store_true')
    args=parser.parse_args()
    if sys.platform!='darwin':parser.error('Build on macOS using the target architecture Python.')
    work=args.work_dir.expanduser().resolve();work.mkdir(parents=True,exist_ok=True)
    arch=platform.machine()
    if arch not in ('arm64','x86_64'):parser.error('Supported build architectures: arm64, x86_64')
    runtime=work/f'ffmpeg-{arch}'
    if not args.skip_ffmpeg:run([ROOT/'packaging/build_ffmpeg.sh',work,arch])
    if not (runtime/'bin/ffmpeg').is_file():raise RuntimeError('Build the portable FFmpeg runtime first.')
    versions=collect_notices(work)
    bundle=bundle_workspace(work,arch,args.bundle_dir)
    env=dict(os.environ,MULTICAM_FFMPEG_PREFIX=str(runtime),MULTICAM_TARGET_ARCH=arch,
             PYINSTALLER_CONFIG_DIR=str(work/f'pyinstaller-cache-{arch}'))
    run([sys.executable,'-m','PyInstaller','--noconfirm','--clean',
         '--workpath',work/f'pyinstaller-work-{arch}','--distpath',bundle/f'dist-{arch}',
         ROOT/'packaging/MulticamStudio.spec'],env=env)
    app=bundle/f'dist-{arch}/Multicam Studio.app'
    report=audit(app)
    run(['/usr/bin/codesign','--verify','--deep','--strict',app])
    # Blank PATH proves bundled FFmpeg/ffprobe, not Homebrew, are used.
    clean_env=dict(os.environ,PATH='/usr/bin:/bin:/usr/sbin:/sbin')
    # Verify the actual install operation too: resource signatures must survive
    # Finder/ditto copy semantics and the runtime must work after relocation.
    with tempfile.TemporaryDirectory(prefix='install-check-',dir=bundle) as check:
        installed=Path(check)/'Multicam Studio.app'
        run(['/usr/bin/ditto',app,installed])
        run(['/usr/bin/codesign','--verify','--deep','--strict',installed])
        run([installed/'Contents/MacOS/MulticamStudio','--self-test'],env=clean_env)
    report['installation_copy_verified']=True
    release=work/'releases';release.mkdir(exist_ok=True)
    stem=f'Multicam-Studio-{VERSION}-macOS-{arch}'
    run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',app,release/(stem+'.zip')])
    sources=release/f'Multicam-Studio-{VERSION}-Sources.zip'
    sources_zip(sources,work)
    if not args.skip_dmg:
        staging=bundle/f'dmg-{arch}';staging.mkdir(exist_ok=True)
        target=staging/'Multicam Studio.app'
        if target.exists():shutil.rmtree(target)
        run(['/usr/bin/ditto',app,target])
        if not (staging/'Applications').exists():(staging/'Applications').symlink_to('/Applications')
        shutil.copy2(sources,staging/sources.name)
        shutil.copy2(ROOT/'packaging/INSTALL.txt',staging/'Install Multicam Studio.txt')
        run(['/usr/bin/hdiutil','create','-volname','Multicam Studio','-srcfolder',staging,
             '-ov','-format','UDZO',release/(stem+'.dmg')])
    report.update(version=VERSION,architecture=arch,supported_macos='14.0+',
                  signing='Developer ID' if env.get('MULTICAM_CODESIGN_IDENTITY') else 'ad-hoc; not notarized',
                  dependencies=versions,build_macos=platform.mac_ver()[0])
    (release/(stem+'-build.json')).write_text(json.dumps(report,indent=2))
    checksums=[]
    for path in sorted(release.iterdir()):
        if path.is_file() and not path.name.startswith('._') and path.suffix in ('.zip','.dmg'):
            checksums.append(hashlib.file_digest(path.open('rb'),'sha256').hexdigest()+'  '+path.name)
    (release/'SHA256SUMS.txt').write_text('\n'.join(checksums)+'\n')
    print(f'APP: {app}\nRELEASES: {release}',flush=True)


if __name__=='__main__':main()
