# Run through build_release.py so paths/version/architecture are explicit.
from pathlib import Path
import os
root = Path(SPECPATH).parent
runtime = Path(os.environ['MULTICAM_FFMPEG_PREFIX'])
architecture = os.environ.get('MULTICAM_TARGET_ARCH', 'arm64')
identity = os.environ.get('MULTICAM_CODESIGN_IDENTITY') or None
analysis = Analysis([str(root/'desktop.py')], pathex=[str(root)],
    binaries=[(str(runtime/'bin/ffmpeg'),'bin'), (str(runtime/'bin/ffprobe'),'bin')],
    datas=[(str(root/'web'),'web'), (str(root/'packaging/notices'),'notices')],
    hiddenimports=['server','multicam_edit','effects','highlights','numpy','scipy.signal','scipy.ndimage','AppKit','Foundation'],
    excludes=['tkinter','matplotlib','IPython','pytest','pandas'], noarchive=False)
# exFAT build environments expose AppleDouble sidecars as ordinary files.
# Never seal them into an app: Finder/ditto removes them while installing it.
def is_appledouble(entry):
    return any(part.startswith('._') for value in entry[:2]
               for part in Path(value).parts)
analysis.datas = [entry for entry in analysis.datas if not is_appledouble(entry)]
analysis.binaries = [entry for entry in analysis.binaries if not is_appledouble(entry)]
pyz = PYZ(analysis.pure)
exe = EXE(pyz, analysis.scripts, [], exclude_binaries=True, name='MulticamStudio',
    debug=False, strip=False, upx=False, console=False, target_arch=architecture,
    codesign_identity=identity, entitlements_file=str(root/'packaging'/('entitlements-intel.plist' if architecture == 'x86_64' else 'entitlements.plist')) if identity else None)
collect = COLLECT(exe, analysis.binaries, analysis.datas, strip=False, upx=False, name='MulticamStudio')
app = BUNDLE(collect, name='Multicam Studio.app', bundle_identifier='com.multicamstudio.desktop',
    version='1.2.0', icon=str(root/'packaging/MulticamStudio.icns'), info_plist={'CFBundleShortVersionString':'1.2.0','CFBundleVersion':'1.2.0','LSMinimumSystemVersion':'14.0',
       'NSHighResolutionCapable':True,'NSHumanReadableCopyright':'Multicam Studio. Third-party notices are included.',
       'NSAppleEventsUsageDescription':'Multicam Studio opens your local editing workspace in your browser.',
       'NSDocumentsFolderUsageDescription':'Select recordings and save exports in folders you choose.',
       'NSRemovableVolumesUsageDescription':'Read camera recordings and save exports on connected drives.'})
