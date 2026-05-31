@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>nul
cd /d "%~dp0"

call :MAIN
set "RC=%ERRORLEVEL%"

echo.
echo ============================================================
if "%RC%"=="0" (
    echo Finished. If the Bokeh server is still running, keep this window open.
) else (
    echo Script stopped with error code %RC%.
    echo Please copy the full text above and send it to the developer.
)
echo Press any key to close this window...
pause >nul
exit /b %RC%

:MAIN
set "ENV_NAME=lego_geomag"
set "APP_FILE=%CD%\geomag_web_app.py"

echo ============================================================
echo Geomagnetic Web App one-click launcher for Windows
echo Project directory: %CD%
echo ============================================================
echo.

if not exist "%APP_FILE%" (
    echo ERROR: geomag_web_app.py was not found in this directory.
    echo Please put this BAT file in the project root directory.
    exit /b 10
)

REM ---- Try conda first, fall back to Python venv ----
call :FIND_CONDA
if "%CONDA_FOUND%"=="1" (
    call :SETUP_CONDA
) else (
    echo Conda not found. Trying Python venv as fallback...
    call :SETUP_VENV
)
exit /b %ERRORLEVEL%

REM ============================================================
REM Conda setup
REM ============================================================
:SETUP_CONDA
echo Using conda: %CONDA_CMD%
echo.

REM Get conda base path
set "CONDA_BASE="
for /f "delims=" %%B in ('call "%CONDA_CMD%" info --base 2^>nul') do (
    if not defined CONDA_BASE set "CONDA_BASE=%%B"
)
if not defined CONDA_BASE (
    echo ERROR: conda info --base failed. Your conda installation may be broken.
    exit /b 12
)
echo Conda base: %CONDA_BASE%

REM Check conda health
call "%CONDA_CMD%" --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: conda --version failed.
    exit /b 13
)

REM Check if environment exists
echo.
echo Checking environment "%ENV_NAME%"...
set "ENV_EXISTS=0"
set "ENV_DIR=%CONDA_BASE%\envs\%ENV_NAME%"
if exist "%ENV_DIR%\python.exe" set "ENV_EXISTS=1"

if "%ENV_EXISTS%"=="0" (
    echo Creating conda environment "%ENV_NAME%" with Python 3.11...
    call "%CONDA_CMD%" create -y -n "%ENV_NAME%" python=3.11 pip
    if errorlevel 1 (
        echo ERROR: Failed to create conda environment.
        echo Try running this in Anaconda Prompt instead, or install Python 3.11+ directly.
        exit /b 15
    )
) else (
    echo Environment "%ENV_NAME%" already exists.
)

REM Use direct Python path to avoid conda-activate issues in batch files
set "PYTHON_EXE=%CONDA_BASE%\envs\%ENV_NAME%\python.exe"
echo Python: %PYTHON_EXE%
echo.

echo Installing Python dependencies...
"%PYTHON_EXE%" -m pip install --upgrade pip --quiet
if errorlevel 1 (
    echo WARNING: pip upgrade failed, continuing anyway...
)

"%PYTHON_EXE%" -m pip install numpy pykrige matplotlib bokeh gstools
if errorlevel 1 (
    echo ERROR: Failed to install required packages.
    exit /b 18
)

if exist "%CD%\pyproject.toml" (
    echo.
    echo Installing local project in editable mode...
    "%PYTHON_EXE%" -m pip install -e "%CD%" --quiet
    if errorlevel 1 (
        echo WARNING: Editable install failed. The app may still work.
    )
)

echo.
echo Starting Bokeh web app...
echo App URL: http://localhost:5006/geomag_web_app
echo Keep this console window open while using the app.
echo.
"%PYTHON_EXE%" -m bokeh serve --show "%APP_FILE%"
if errorlevel 1 (
    echo ERROR: Bokeh failed to start.
    exit /b 20
)
exit /b 0

REM ============================================================
REM Python venv fallback (no conda required)
REM ============================================================
:SETUP_VENV
echo Looking for Python 3.11+...
set "PYTHON_EXE="

REM Try 'py' launcher first (most reliable on Windows), then 'python', skip 'python3' stubs
for %%C in (py python) do (
    if not defined PYTHON_EXE (
        for /f "delims=" %%P in ('where %%C 2^>nul') do (
            if not defined PYTHON_EXE (
                echo %%P | findstr /I "WindowsApps" >nul 2>&1
                if errorlevel 1 set "PYTHON_EXE=%%P"
            )
        )
    )
)

if not defined PYTHON_EXE (
    echo ERROR: Python was not found on your system.
    echo.
    echo The Microsoft Store Python stub ^(WindowsApps^) does NOT work.
    echo Please install real Python from one of:
    echo   1. https://www.python.org/downloads/  ^(recommended^)
    echo   2. Miniconda: https://docs.conda.io/en/latest/miniconda.html
    echo.
    echo After installing, run this script again.
    exit /b 21
)

echo Found Python: %PYTHON_EXE%
"%PYTHON_EXE%" --version 2>&1
if errorlevel 1 (
    echo ERROR: Python at %PYTHON_EXE% is broken or not functional.
    echo Please reinstall Python from https://www.python.org/downloads/
    exit /b 21
)
echo.

set "VENV_DIR=%CD%\.venv"

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo Creating Python virtual environment in .venv...
    "%PYTHON_EXE%" -m venv "%VENV_DIR%"
    if errorlevel 1 (
        echo ERROR: Failed to create virtual environment.
        echo Make sure you have Python 3.11+ with venv support.
        exit /b 22
    )
) else (
    echo Virtual environment already exists.
)

set "VENV_PYTHON=%VENV_DIR%\Scripts\python.exe"
echo Venv Python: %VENV_PYTHON%
echo.

echo Installing Python dependencies...
"%VENV_PYTHON%" -m pip install --upgrade pip --quiet
"%VENV_PYTHON%" -m pip install numpy pykrige matplotlib bokeh gstools
if errorlevel 1 (
    echo ERROR: Failed to install required packages.
    echo On Windows, pykrige and gstools may need a C++ compiler.
    echo Try installing Miniconda instead: https://docs.conda.io/en/latest/miniconda.html
    exit /b 23
)

if exist "%CD%\pyproject.toml" (
    echo.
    echo Installing local project in editable mode...
    "%VENV_PYTHON%" -m pip install -e "%CD%" --quiet
)

echo.
echo Starting Bokeh web app...
echo App URL: http://localhost:5006/geomag_web_app
echo Keep this console window open while using the app.
echo.
"%VENV_PYTHON%" -m bokeh serve --show "%APP_FILE%"
if errorlevel 1 (
    echo ERROR: Bokeh failed to start.
    exit /b 24
)
exit /b 0

REM ============================================================
REM Find conda installation
REM ============================================================
:FIND_CONDA
set "CONDA_FOUND=0"
set "CONDA_CMD="

REM Check common install locations
if exist "%USERPROFILE%\anaconda3\condabin\conda.bat"       set "CONDA_CMD=%USERPROFILE%\anaconda3\condabin\conda.bat"
if not defined CONDA_CMD if exist "%USERPROFILE%\miniconda3\condabin\conda.bat"       set "CONDA_CMD=%USERPROFILE%\miniconda3\condabin\conda.bat"
if not defined CONDA_CMD if exist "%USERPROFILE%\miniforge3\condabin\conda.bat"       set "CONDA_CMD=%USERPROFILE%\miniforge3\condabin\conda.bat"
if not defined CONDA_CMD if exist "%LOCALAPPDATA%\anaconda3\condabin\conda.bat"       set "CONDA_CMD=%LOCALAPPDATA%\anaconda3\condabin\conda.bat"
if not defined CONDA_CMD if exist "%LOCALAPPDATA%\miniconda3\condabin\conda.bat"       set "CONDA_CMD=%LOCALAPPDATA%\miniconda3\condabin\conda.bat"
if not defined CONDA_CMD if exist "C:\ProgramData\anaconda3\condabin\conda.bat"       set "CONDA_CMD=C:\ProgramData\anaconda3\condabin\conda.bat"
if not defined CONDA_CMD if exist "C:\ProgramData\miniconda3\condabin\conda.bat"       set "CONDA_CMD=C:\ProgramData\miniconda3\condabin\conda.bat"
if not defined CONDA_CMD if exist "C:\ProgramData\miniforge3\condabin\conda.bat"       set "CONDA_CMD=C:\ProgramData\miniforge3\condabin\conda.bat"

REM Also try conda in PATH
if not defined CONDA_CMD (
    for /f "delims=" %%C in ('where conda 2^>nul') do (
        if not defined CONDA_CMD set "CONDA_CMD=%%C"
    )
)

if defined CONDA_CMD set "CONDA_FOUND=1"
exit /b 0
