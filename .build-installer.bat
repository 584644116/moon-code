@echo off
rem Builds the Windows installer, and says beforehand what would stop it.
rem
rem   .build-installer.bat            build, then package
rem   .build-installer.bat --check    only ask what the build needs
rem
rem The one thing that stops a build here and cannot be fixed from a script:
rem Windows will not walk a symlink this process made, unless the token holds
rem SeCreateSymbolicLinkPrivilege (an administrator's does). `flutter build
rem windows` links every plugin into windows\flutter\ephemeral\.plugin_symlinks
rem and CMake reads them; a link that cannot be walked fails as "add_subdirectory
rem given source ... which is not an existing directory", naming no plugin.
rem
rem So: if that check fails, run this from an administrator's Command Prompt
rem once. The links stay (flutter/ephemeral is gitignored), and every later
rem build in an ordinary terminal finds them.

setlocal
set FLUTTER=D:\DM\_sdk\flutter\bin
set REPO=%~dp0
if "%REPO:~-1%"=="\" set REPO=%REPO:~0,-1%

set PATH=%FLUTTER%;%PATH%
cd /d "%REPO%"

dart run tool/build_windows.dart --stock-engine %*
set CODE=%ERRORLEVEL%
echo exit=%CODE%
if not "%CODE%"=="0" (
  echo.
  echo Build failed. The reason is above; docs\release.md section 8 has the
  echo ones that come up on this machine.
)
exit /b %CODE%
