@echo off
setlocal EnableDelayedExpansion
set /a _Debug=0

set _Args=%*
if "%~1" NEQ "" (
  set _Args=%_Args:"=%
)

:: Check if elevation should be skipped (e.g. headless tests)
set "SKIP_ELEVATE=0"
echo %* | findstr /i "\-\-no\-elevate" >nul 2>&1 && set "SKIP_ELEVATE=1"

if "%SKIP_ELEVATE%"=="0" (
    fltmc 1>nul 2>nul || (
        cd /d "%~dp0"
        if defined _Args (
            cmd /u /c echo Set UAC = CreateObject^("Shell.Application"^) : UAC.ShellExecute "cmd.exe", "/c cd /d ""%~dp0"" && ""%~dpnx0"" %_Args%", "", "runas", 1 > "%temp%\GetAdmin.vbs"
        ) else (
            cmd /u /c echo Set UAC = CreateObject^("Shell.Application"^) : UAC.ShellExecute "cmd.exe", "/c cd /d ""%~dp0"" && ""%~dpnx0""", "", "runas", 1 > "%temp%\GetAdmin.vbs"
        )
        "%temp%\GetAdmin.vbs"
        del /f /q "%temp%\GetAdmin.vbs" 1>nul 2>nul
        exit /b
    )
)

cd /d "%~dp0"

echo ======================================================================
echo   Configurador WAMP PHP CLI y Composer (Modo Administrador)
echo ======================================================================

set "NONINTERACTIVE=0"
for %%A in (%*) do (
    if /i "%%~A"=="-NonInteractive" set "NONINTERACTIVE=1"
)

:: Filter out internal --no-elevate before passing to PowerShell
set "PS_ARGS="
for %%A in (%*) do (
    if /i "%%~A" neq "--no-elevate" (
        set "PS_ARGS=!PS_ARGS! %%A"
    )
)

:: Execute the PowerShell script with ExecutionPolicy Bypass
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_wamp_env.ps1" %PS_ARGS%

if "%NONINTERACTIVE%"=="1" (
    exit /b %errorlevel%
)

echo.
echo ======================================================================
echo   Proceso finalizado. Presiona cualquier tecla para salir.
echo ======================================================================
pause >nul
endlocal
