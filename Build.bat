@echo off
pwsh -NoProfile -File "%~dp0Build.ps1" %*
exit /b %ERRORLEVEL%
