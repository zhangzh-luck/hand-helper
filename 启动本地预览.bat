@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Starts the local frontend and backend. Vite listens on the LAN, too.
set "PROJECT_ROOT=%~dp0"
set "BACKEND_DIR=%PROJECT_ROOT%backend"
set "WEB_DIR=%PROJECT_ROOT%web"
set "BACKEND_PYTHON=%BACKEND_DIR%\.venv\Scripts\python.exe"

if not exist "%BACKEND_PYTHON%" (
  echo [ERROR] Backend virtual environment not found:
  echo %BACKEND_PYTHON%
  echo Install backend dependencies before starting the preview.
  pause
  exit /b 1
)

where node >nul 2>nul
if errorlevel 1 (
  echo [ERROR] Node.js was not found. Install a Node.js LTS release first.
  pause
  exit /b 1
)

set "FRONTEND_COMMAND="
where pnpm >nul 2>nul
if not errorlevel 1 (
  set "FRONTEND_COMMAND=pnpm exec vite --host 0.0.0.0 --port 5173"
) else (
  where npm >nul 2>nul
  if errorlevel 1 (
    echo [ERROR] Neither pnpm nor npm was found. Reinstall Node.js first.
    pause
    exit /b 1
  )
  echo [INFO] pnpm was not found. Falling back to npm.
  set "FRONTEND_COMMAND=npm exec vite -- --host 0.0.0.0 --port 5173"
)

set "BACKEND_RUNNING="
set "FRONTEND_RUNNING="
for %%P in (5173 8000) do (
  set "PORT_PID="
  for /f "tokens=5" %%A in ('netstat -ano ^| findstr /C:":%%P " ^| findstr /C:"LISTENING"') do set "PORT_PID=%%A"
  if defined PORT_PID (
    echo [INFO] Port %%P is already used by PID !PORT_PID!. The existing service will be kept.
    if "%%P"=="5173" (set "FRONTEND_RUNNING=1") else (set "BACKEND_RUNNING=1")
  )
)

if defined BACKEND_RUNNING (
  echo Backend is already available on http://localhost:8000
) else (
  echo Starting backend: http://localhost:8000
  start "Hand Helper Backend" /D "%BACKEND_DIR%" "%ComSpec%" /k call "%BACKEND_PYTHON%" -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
)

if defined FRONTEND_RUNNING (
  echo Frontend is already available on http://localhost:5173/login
) else (
  echo Starting frontend: http://localhost:5173/login
  start "Hand Helper Frontend" /D "%WEB_DIR%" "%ComSpec%" /k call !FRONTEND_COMMAND!
)

set /a "WAIT_SECONDS=0"
:wait_for_frontend
powershell -NoProfile -Command "try { $response = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:5173/login' -TimeoutSec 1; exit [int]($response.StatusCode -ne 200) } catch { exit 1 }" >nul 2>nul
if not errorlevel 1 goto frontend_ready

set /a "WAIT_SECONDS+=1"
if %WAIT_SECONDS% GEQ 20 goto frontend_timeout
timeout /t 1 /nobreak >nul
goto wait_for_frontend

:frontend_ready
powershell -NoProfile -Command "Start-Process 'http://localhost:5173/login'" >nul 2>nul

echo.
echo Local preview is ready: http://localhost:5173/login
echo For LAN preview, use this computer's IPv4 address with :5173/login.
echo Frontend and backend logs are shown in their own command windows.
goto end

:frontend_timeout
echo.
echo [ERROR] The frontend was not ready after 20 seconds.
echo Check the "Hand Helper Frontend" window for the exact error.
pause
exit /b 1

:end
endlocal
