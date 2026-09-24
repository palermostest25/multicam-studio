@echo off
rem UI demo: needs only Python. No venv, pip, NumPy, SciPy or FFmpeg.
cd /d "%~dp0"
where py >nul 2>nul && (py -3 demo.py --open %* & goto :end)
where python >nul 2>nul && (python demo.py --open %* & goto :end)
echo Python 3.10 or newer is required. Install it from https://www.python.org/downloads/
:end
pause
