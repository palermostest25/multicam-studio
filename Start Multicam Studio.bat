@echo off
rem Double-click to start Multicam Studio on Windows. Processing and media stay on this PC.
setlocal
cd /d "%~dp0"

where ffmpeg >nul 2>nul || goto :no_ffmpeg
where ffprobe >nul 2>nul || goto :no_ffmpeg

set "PYTHON=%~dp0.venv\Scripts\python.exe"
if exist "%PYTHON%" goto :have_venv
set "BASE="
where py >nul 2>nul && set "BASE=py -3"
if not defined BASE where python >nul 2>nul && set "BASE=python"
if not defined BASE goto :no_python
%BASE% -c "import sys; sys.exit(sys.version_info < (3, 10))" >nul 2>nul || goto :no_python
echo Creating the local Python environment...
%BASE% -m venv "%~dp0.venv" || goto :fail_venv

:have_venv
"%PYTHON%" -c "import sys; sys.exit(sys.version_info < (3, 10))" >nul 2>nul || goto :old_python
"%PYTHON%" -c "import numpy, scipy" >nul 2>nul && goto :start
echo Installing NumPy and SciPy (internet needed for this first setup)...
"%PYTHON%" -m pip install -r "%~dp0requirements.txt" || goto :fail_pip

:start
echo.
echo Multicam Studio is starting in your browser.
echo Keep this window open while editing or rendering. Press Ctrl+C here to stop.
echo.
"%PYTHON%" "%~dp0server.py" --open %*
exit /b %errorlevel%

:no_ffmpeg
call :fail "FFmpeg and FFprobe are required. Install them with: winget install Gyan.FFmpeg  (then reopen this window)"
exit /b 1
:no_python
call :fail "Python 3.10 or newer is required. Install it from https://www.python.org/downloads/ or with: winget install Python.Python.3.12"
exit /b 1
:old_python
call :fail "This Python environment is too old. Install Python 3.10 or newer and delete the .venv folder."
exit /b 1
:fail_venv
call :fail "Could not create the Python environment. Check the folder is writable."
exit /b 1
:fail_pip
call :fail "Could not install dependencies. Check your internet connection, then run this again."
exit /b 1

:fail
echo.
echo %~1
pause
exit /b 1
