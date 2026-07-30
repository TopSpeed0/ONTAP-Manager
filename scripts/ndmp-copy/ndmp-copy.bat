@echo off
REM NDMP Copy wrapper — calls Ndmp_Copy.ps1 with config.json lookups.
REM All parameters are optional — defaults come from NDMP_Config in config.json.
REM Usage: ndmp-copy.bat [SrcCluster] [DstCluster] [SourcePath] [DestPath]
REM   No args  → uses SrcCluster, DstCluster, SRC, DST from config.json
REM   With args → overrides config defaults

set "ARGS="
if not "%~1"=="" set "ARGS=%ARGS% -SrcCluster "%~1""
if not "%~2"=="" set "ARGS=%ARGS% -DstCluster "%~2""
if not "%~3"=="" set "ARGS=%ARGS% -SourcePath "%~3""
if not "%~4"=="" set "ARGS=%ARGS% -DestPath "%~4""

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Ndmp_Copy.ps1" %ARGS%
pause
