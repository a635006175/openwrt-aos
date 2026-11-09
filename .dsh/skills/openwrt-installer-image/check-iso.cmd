@echo off
rem ===========================================================================
rem  check-iso.cmd -- Windows 本地一键静态体检
rem
rem  用法：
rem    check-iso.cmd <path\to\image.iso>
rem    check-iso.cmd <path\to\image.iso> --expect-kernel-sha fd30ff91...
rem
rem  作用：不装任何东西、不开 QEMU，3 秒内判断镜像能不能启动。
rem        把两轮实机排障得出的全部启动级故障都变成了检查项。
rem ===========================================================================
setlocal EnableDelayedExpansion

rem %~dp0 自带尾反斜杠，且里面可能含 ".."；python 不会自动规范化，
rem 所以用 pushd/popd 拿到真实路径再拼。之前直接拼接导致
rem "can't open file ...\..\scripts\check-iso.py"。
set "SKILLDIR=%~dp0."
pushd "%SKILLDIR%" 2>nul || (echo [ERROR] 找不到技能目录 & exit /b 2)
set "SKILLDIR=%CD%"
popd

set "PY="
if exist "%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe" (
  set "PY=%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
)
if not defined PY (
  if exist "%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" (
    set "PY=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
  )
)
if not defined PY (
  where python >nul 2>&1 && set "PY=python"
)
if not defined PY (
  where python3 >nul 2>&1 && set "PY=python3"
)
if not defined PY (
  echo [ERROR] 找不到 python，请安装 Python 3.8+ 或从 DSH 目录运行。
  exit /b 2
)

set PYTHONIOENCODING=utf-8
chcp 65001 >nul 2>&1

if "%~1"=="" (
  echo 用法: check-iso.cmd ^<image.iso^> [--expect-kernel-sha ^<sha256^>] [--json]
  exit /b 2
)

"%PY%" "%SKILLDIR%\scripts\check-iso.py" %*
exit /b %ERRORLEVEL%
