@echo off
setlocal enabledelayedexpansion

rem Nim wrapper for issue #1609 test.
rem Logs invocations to calls.log, then delegates to the real nim by
rem finding the first 'nim' in PATH that isn't this wrapper's directory.

rem Normalize current script directory to short path to avoid mismatch issues
for %%A in ("%~dp0") do set "MYDIR=%%~sA"

rem Log the call (using ( to handle empty arguments safely)
echo(%* >> "%~dp0calls.log"

rem Iterate through all 'nim' executables found in PATH
for /f "delims=" %%i in ('where nim 2^>nul') do (
    set "CANDIDATE=%%i"
    for %%B in ("%%~dpi") do set "CAN_DIR=%%~sB"

    rem If the directory of the found nim is not our own directory
    if /i not "!CAN_DIR!"=="!MYDIR!" (
        "!CANDIDATE!" %*
        exit /b !ERRORLEVEL!
    )
)

rem If we got here, we didn't find the real nim
echo Error: Real nim.exe not found in PATH >&2
exit /b 1
