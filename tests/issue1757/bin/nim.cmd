@echo off
setlocal enabledelayedexpansion

rem Nim wrapper for issue #1757 test. See bin/nim for the rationale.
rem Simulates a layout where querySetting(libPath) points at a directory whose
rem parent has no nim.nimble; all other calls delegate to the real nim.

for %%A in ("%~dp0") do set "MYDIR=%%~sA"
echo(%* >> "%~dp0calls.log"

echo(%*| findstr /C:"querySetting" >nul
if not errorlevel 1 (
  echo(%*| findstr /C:"libPath" >nul
  if not errorlevel 1 (
    echo %~dp0fakelib\nim
    exit /b 0
  )
)

for /f "delims=" %%i in ('where nim 2^>nul') do (
    set "CANDIDATE=%%i"
    for %%B in ("%%~dpi") do set "CAN_DIR=%%~sB"
    if /i not "!CAN_DIR!"=="!MYDIR!" (
        "!CANDIDATE!" %*
        exit /b !ERRORLEVEL!
    )
)

echo Error: Real nim.exe not found in PATH >&2
exit /b 1
