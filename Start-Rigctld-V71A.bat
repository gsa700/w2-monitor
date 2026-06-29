@echo off
REM ============================================================
REM  Launch Hamlib rigctld for the Kenwood TM-V71A, shared on TCP
REM  so W2 Monitor and other apps can all read the rig at once.
REM ============================================================

REM --- EDIT THIS to the folder where you unzipped Hamlib (the one with rigctld.exe) ---
set "HAMLIB_BIN=C:\hamlib\bin"

REM --- Radio settings (model 2035 = Kenwood TM-V71A; run "rigctl.exe --list" to find others) ---
set "MODEL=2035"
set "PORT=COM7"
set "SPEED=57600"
set "TCP=4532"

echo.
echo Starting rigctld: TM-V71A on %PORT% @ %SPEED%, serving TCP port %TCP%
echo (DTR/RTS forced ON - the V71A cable needs them.)
echo Leave this window open. Close it to stop sharing the radio.
echo.

if not exist "%HAMLIB_BIN%\rigctld.exe" (
  echo ERROR: rigctld.exe not found in "%HAMLIB_BIN%".
  echo Edit HAMLIB_BIN at the top of this file to your Hamlib bin folder.
  pause
  exit /b 1
)

"%HAMLIB_BIN%\rigctld.exe" -m %MODEL% -r %PORT% -s %SPEED% -t %TCP% --set-conf=dtr_state=ON,rts_state=ON

echo.
echo rigctld exited.
pause
