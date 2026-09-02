@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================================
rem  crdb.bat - drive the course's lab cluster on Windows.
rem  Everything runs in Docker; there is no cockroach binary to install.
rem
rem    scripts\crdb.bat up             start a 3-node cluster and initialise it
rem    scripts\crdb.bat sql            open a SQL shell on node 1
rem    scripts\crdb.bat sql -e "..."   run SQL non-interactively
rem    scripts\crdb.bat sql-on 2       open a SQL shell on node 2
rem    scripts\crdb.bat status         node status
rem    scripts\crdb.bat stop 2         stop node 2 (simulate a failure)
rem    scripts\crdb.bat start 2        bring node 2 back
rem    scripts\crdb.bat add-node       start a 4th node
rem    scripts\crdb.bat run <cmd...>   any cockroach subcommand on node 1
rem    scripts\crdb.bat console        print the DB Console URL
rem    scripts\crdb.bat logs [n]       tail a node's logs
rem    scripts\crdb.bat down           remove the cluster AND its data
rem    scripts\crdb.bat reset          down, then up
rem ============================================================================

set "RC=0"
pushd "%~dp0.." >nul 2>&1 || (echo [ERROR] cannot find the repository folder & exit /b 1)
rem CRDB_COMPOSE selects which cluster to drive:
rem   docker/labs.yml         the main 3-node cluster (default)
rem   docker/labs-b.yml       Lab 11's standby cluster
rem   docker/labs-secure.yml  Lab 12's TLS cluster
if "%CRDB_COMPOSE%"=="" set "CRDB_COMPOSE=docker/labs.yml"
set "COMPOSE=docker compose -f %CRDB_COMPOSE%"

set "NODE=crdb"
set "HTTP0=8080"
set "SQL0=26257"
set "AUTH=--insecure"
rem Substring tests without spawning find, which needs a pipeline and quoting care.
if not "%CRDB_COMPOSE%"=="%CRDB_COMPOSE:labs-b=%" (
    set "NODE=crdbb"
    set "HTTP0=8180"
    set "SQL0=26357"
)
if not "%CRDB_COMPOSE%"=="%CRDB_COMPOSE:labs-secure=%" (
    set "NODE=crdbs"
    set "HTTP0=8280"
    set "SQL0=26457"
    set "AUTH=--certs-dir=/certs --host=crdbs1"
)

set "CMD=%~1"
if "%CMD%"=="" set "CMD=help"
shift

if /i "%CMD%"=="help"   goto :help
if /i "%CMD%"=="--help" goto :help
if /i "%CMD%"=="-h"     goto :help

docker info >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Docker is not running. Start Docker Desktop and try again.
    set "RC=1"
    goto :done
)

rem ARG1 is the first argument after the command - the node number for
rem stop/start/sql-on/logs. Capture it before :collect shifts everything away.
set "ARG1=%~1"

rem Rebuild the remaining arguments into ARGS.
set "ARGS="
:collect
if "%~1"=="" goto :dispatch
set "ARGS=!ARGS! %1"
shift
goto :collect

:dispatch
if /i "%CMD%"=="up"       goto :up
if /i "%CMD%"=="sql"      goto :sql
if /i "%CMD%"=="sql-on"   goto :sqlon
if /i "%CMD%"=="run"      %COMPOSE% exec %NODE%1 ./cockroach!ARGS! & goto :done
if /i "%CMD%"=="status"   %COMPOSE% exec %NODE%1 ./cockroach node status %AUTH% & goto :done
if /i "%CMD%"=="stop"     goto :stopnode
if /i "%CMD%"=="start"    goto :startnode
if /i "%CMD%"=="add-node" goto :addnode
if /i "%CMD%"=="console"  goto :console
if /i "%CMD%"=="logs"     goto :logs
if /i "%CMD%"=="ps"       %COMPOSE% ps & goto :done
if /i "%CMD%"=="cp"       %COMPOSE% cp!ARGS! & goto :done
if /i "%CMD%"=="down"     %COMPOSE% --profile scale down -v & goto :done
if /i "%CMD%"=="reset"    goto :reset
echo [ERROR] unknown command "%CMD%"
goto :help

:up
if not "%CRDB_COMPOSE%"=="%CRDB_COMPOSE:labs-secure=%" (
    %COMPOSE% up -d
    echo Waiting for the secure node...
    timeout /t 12 /nobreak >nul
    %COMPOSE% exec -T %NODE%1 ./cockroach cert list --certs-dir=/certs
    echo.
    echo DB Console: https://localhost:%HTTP0%  ^(self-signed certificate^)
    goto :done
)
%COMPOSE% up -d %NODE%1 %NODE%2 %NODE%3
if errorlevel 1 (set "RC=1" & goto :done)
echo Waiting for the cluster to initialise...
%COMPOSE% up init
rem Nodes join through gossip after init returns; wait so the list below is complete.
rem The count is written to a file and read back: parsing a command's output inside
rem for /f means nesting quotes, which cmd mangles.
echo Waiting for all nodes to join...
set "COUNTFILE=%TEMP%\crdb_nodecount.txt"
for /l %%i in (1,1,60) do (
    %COMPOSE% exec -T %NODE%1 ./cockroach sql %AUTH% --format=csv -e "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live" > "%COUNTFILE%" 2>nul
    set "LIVE="
    for /f "usebackq skip=1 delims=" %%n in ("%COUNTFILE%") do if not defined LIVE set "LIVE=%%n"
    if "!LIVE!"=="3" goto :up_ready
    timeout /t 2 /nobreak >nul
)
:up_ready
del "%COUNTFILE%" 2>nul
%COMPOSE% exec -T %NODE%1 ./cockroach sql %AUTH% -e "SELECT node_id, address, is_live FROM crdb_internal.gossip_nodes ORDER BY node_id;"
echo.
echo DB Console: http://localhost:%HTTP0%   ^(SQL on localhost:%SQL0%^)
goto :done

:sql
rem With arguments (e.g. -e "..."), run without a TTY so output can be piped or
rem redirected. With no arguments, allocate a TTY for an interactive shell.
if "!ARGS!"=="" (
    %COMPOSE% exec %NODE%1 ./cockroach sql %AUTH%
) else (
    %COMPOSE% exec -T %NODE%1 ./cockroach sql %AUTH%!ARGS!
)
goto :done

:sqlon
set "N=%ARG1%"
if "%N%"=="" set "N=1"
rem ARGS starts with the node number; drop that token before passing the rest on.
set "REST=!ARGS!"
if not "%ARG1%"=="" call set "REST=%%REST: %ARG1%=%%"
%COMPOSE% exec %NODE%%N% ./cockroach sql %AUTH%!REST!
goto :done

:stopnode
if "%ARG1%"=="" (echo usage: crdb.bat stop ^<node-number^> & set "RC=1" & goto :done)
%COMPOSE% stop %NODE%%ARG1%
goto :done

:startnode
if "%ARG1%"=="" (echo usage: crdb.bat start ^<node-number^> & set "RC=1" & goto :done)
%COMPOSE% start %NODE%%ARG1%
goto :done

:addnode
%COMPOSE% --profile scale up -d %NODE%4
echo Node 4 started ^(one port above node 3^)
goto :done

:console
echo http://localhost:%HTTP0%  ^(SQL on localhost:%SQL0%^)
goto :done

:logs
set "N=%ARG1%"
if "%N%"=="" set "N=1"
%COMPOSE% logs -f %NODE%%N%
goto :done

:reset
%COMPOSE% --profile scale down -v
call "%~f0" up
goto :done

:help
echo.
echo crdb.bat - drive the course's lab cluster (everything runs in Docker)
echo.
echo   scripts\crdb.bat up             start a 3-node cluster and initialise it
echo   scripts\crdb.bat sql            open a SQL shell on node 1
echo   scripts\crdb.bat sql -e "..."   run SQL non-interactively
echo   scripts\crdb.bat sql-on 2       open a SQL shell on node 2
echo   scripts\crdb.bat status         node status
echo   scripts\crdb.bat stop 2         stop node 2 (simulate a failure)
echo   scripts\crdb.bat start 2        bring node 2 back
echo   scripts\crdb.bat add-node       start a 4th node
echo   scripts\crdb.bat run ^<cmd...^>   any cockroach subcommand on node 1
echo   scripts\crdb.bat console        print the DB Console URL
echo   scripts\crdb.bat logs [n]       tail a node's logs
echo   scripts\crdb.bat ps             container status
echo   scripts\crdb.bat cp ^<src^> ^<dst^> copy a file into/out of a container
echo   scripts\crdb.bat down           remove the cluster AND its data
echo   scripts\crdb.bat reset          down, then up
echo.
echo Set CRDB_COMPOSE to pick a different cluster:
echo   docker/labs.yml         main 3-node cluster (default)
echo   docker/labs-b.yml       Lab 11 standby cluster
echo   docker/labs-secure.yml  Lab 12 TLS cluster
echo.
goto :done

:done
popd >nul 2>&1
endlocal & exit /b %RC%
