@echo off
REM Launch ChrisTitusTech WinUtil (elevated). https://github.com/christitustech/winutil
REM WinUtil performs system-wide changes and must run as Administrator.
REM Pass -dev to use the development branch (windev) instead of stable.
set "_WU_URL=https://christitus.com/win"
if /I "%~1"=="-dev" set "_WU_URL=https://christitus.com/windev"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command','irm %_WU_URL% | iex'"
