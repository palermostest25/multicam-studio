#!/usr/bin/env python3
"""Native macOS entrypoint and frozen engine/effects worker dispatcher."""
from __future__ import annotations
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading
import traceback
import urllib.error
import urllib.request
import webbrowser


def prepare_runtime():
    root = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
    binary = root / 'bin'
    if binary.is_dir():
        os.environ['PATH'] = str(binary) + os.pathsep + '/usr/bin:/bin:/usr/sbin:/sbin'
    os.environ['PYTHONUNBUFFERED'] = '1'
    return root


def worker(kind, arguments):
    sys.argv = [kind + '.py', *arguments]
    try:
        if kind == 'multicam_edit':
            import multicam_edit
            multicam_edit.main()
        elif kind == 'audio_batch':
            import audio_batch
            audio_batch.main()
        else:
            import effects
            effects.main()
        return 0
    except KeyboardInterrupt:
        print('Cancelled; temporary work files removed.', flush=True)
        return 130
    except Exception as exc:
        print(f'ERROR: {exc}', flush=True)
        return 1


def self_test():
    import numpy as np
    import scipy
    from scipy import signal, ndimage
    assert signal.correlate(np.array([1., 2.]), np.array([1., 2.])).max() == 5
    assert ndimage.uniform_filter1d(np.ones(5), 3).min() == 1
    with tempfile.TemporaryDirectory(prefix='multicam-runtime-check-') as folder:
        output = Path(folder) / 'check.mp4'
        p = subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-y',
             '-f', 'lavfi', '-i', 'color=c=blue:s=160x90:r=24:d=0.5',
             '-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.5',
             '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-t', '0.5', str(output)],
             capture_output=True, text=True)
        if p.returncode: raise RuntimeError(p.stderr)
        result = subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', str(output)],
                                capture_output=True, text=True, check=True)
        assert len(json.loads(result.stdout)['streams']) == 2
    print(json.dumps({'status': 'ok', 'python': sys.version.split()[0], 'numpy': np.__version__,
                      'scipy': scipy.__version__, 'frozen': bool(getattr(sys, 'frozen', False)),
                      'ffmpeg': subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0]}), flush=True)


def main():
    prepare_runtime()
    arguments = sys.argv[1:]
    if arguments and arguments[0] in ('--engine', '--effects', '--audio-batch'):
        return worker({'--engine':'multicam_edit','--effects':'effects','--audio-batch':'audio_batch'}[arguments[0]], arguments[1:])
    if arguments == ['--self-test']:
        self_test()
        return 0
    # --headless is for build/integration checks and uses the same packaged server.
    headless = '--headless' in arguments
    arguments = [a for a in arguments if a != '--headless' and not a.startswith('-psn_')]
    state = Path.home() / 'Library/Application Support/Multicam Studio'
    defaults = ['--host', '127.0.0.1', '--port', '8765', '--state-dir', str(state),
                '--default-folder', str(Path.home() / 'Movies')]
    if '--state-dir' in arguments:
        state = Path(arguments[arguments.index('--state-dir') + 1]).expanduser().resolve()
    if not headless:
        logs = Path.home() / 'Library/Logs/Multicam Studio'
        logs.mkdir(parents=True, exist_ok=True)
        stream = (logs / 'desktop.log').open('a', buffering=1, encoding='utf-8')
        sys.stdout = sys.stderr = stream
        defaults += ['--open']
    sys.argv = ['server.py', *defaults, *arguments]
    import server
    if headless:
        server.main()
        return 0
    from AppKit import (NSApplication, NSApplicationActivationPolicyRegular, NSAlert,
                        NSMenu, NSMenuItem, NSTerminateNow, NSTerminateCancel)
    from Foundation import NSObject, NSTimer
    result = {'finished': False, 'error': None, 'stopping': False}
    def stop_server(signum, frame):
        result['stopping'] = True
        server.request_stop()
    previous_handlers = {sig: signal.signal(sig, stop_server)
                         for sig in (signal.SIGINT, signal.SIGTERM)}
    def run_server():
        try: server.main()
        except BaseException as exc:
            result['error'] = str(exc)
            traceback.print_exc()
        finally: result['finished'] = True
    thread = threading.Thread(target=run_server, name='Multicam local server', daemon=True)
    def running_url():
        try:
            info = json.loads((state / 'server.lock').read_text())
            url = info['url']
            if re.fullmatch(r'http://127\.0\.0\.1:[0-9]+', url): return url
        except (OSError, ValueError, KeyError): pass
        return None
    def alert(message):
        box = NSAlert.alloc().init()
        box.setMessageText_('Multicam Studio')
        box.setInformativeText_(message)
        box.addButtonWithTitle_('OK')
        box.runModal()
    class Delegate(NSObject):
        def applicationDidFinishLaunching_(self, notification):
            thread.start()
            self.timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(.4, self, 'checkServer:', None, True)
        def checkServer_(self, timer):
            if result['stopping'] and not result['finished']:
                server.request_stop()
            if result['finished']:
                timer.invalidate()
                if result['error']:
                    alert(result['error'] + '\n\nDetails are saved in ~/Library/Logs/Multicam Studio/desktop.log')
                    result['error'] = None
                NSApplication.sharedApplication().terminate_(None)
        def applicationShouldHandleReopen_hasVisibleWindows_(self, application, visible):
            self.openStudio_(None)
            return True
        def openStudio_(self, sender):
            url = running_url()
            if url: webbrowser.open(url)
        def applicationShouldTerminate_(self, application):
            if result['finished']: return NSTerminateNow
            url = running_url()
            if not url:
                alert('Studio is still starting. Please wait a moment and try again.')
                return NSTerminateCancel
            try:
                with urllib.request.urlopen(url, timeout=3) as response:
                    page = response.read().decode()
                match = re.search(r'window\.MULTICAM_TOKEN\s*=\s*("[^"]+")', page)
                if not match: raise RuntimeError('Could not connect to the running workspace.')
                request = urllib.request.Request(url + '/api/shutdown', data=b'{}',
                    headers={'Content-Type': 'application/json', 'X-Multicam-Token': json.loads(match.group(1))})
                with urllib.request.urlopen(request, timeout=5): pass
            except urllib.error.HTTPError as exc:
                try: message = json.load(exc).get('error', str(exc))
                except Exception: message = str(exc)
                alert(message)
            except Exception as exc: alert(str(exc))
            return NSTerminateCancel  # timer exits after the server cleans up
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyRegular)
    delegate = Delegate.alloc().init()
    app.setDelegate_(delegate)
    menu = NSMenu.alloc().init()
    top = NSMenuItem.alloc().init()
    menu.addItem_(top)
    submenu = NSMenu.alloc().initWithTitle_('Multicam Studio')
    item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_('Open Multicam Studio', 'openStudio:', 'o')
    item.setTarget_(delegate)
    submenu.addItem_(item)
    submenu.addItem_(NSMenuItem.separatorItem())
    submenu.addItem_(NSMenuItem.alloc().initWithTitle_action_keyEquivalent_('Quit Multicam Studio', 'terminate:', 'q'))
    top.setSubmenu_(submenu)
    app.setMainMenu_(menu)
    try:
        app.run()
    finally:
        server.request_stop()
        if thread.is_alive(): thread.join(timeout=17)
        for sig, handler in previous_handlers.items(): signal.signal(sig, handler)
    return 0


if __name__ == '__main__':
    try: sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.exit(1)
