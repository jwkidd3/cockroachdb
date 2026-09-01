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
rem   docker-compose.labs.yml         the main 3-node cluster (default)
rem   docker-compose.labs-b.yml       Lab 11's standby cluster
rem   docker-compose.labs-secure.yml  Lab 12's TLS cluster
if "%CRDB_COMPOSE%"=="" set "CRDB_COMPOSE=docker-compose.labs.yml"
set "COMPOSE=docker compose -f %CRDB_COMPOSE%"

set "NODE=crdb"
set "HTTP0=8080"
set "SQL0=26257"
set "AUTH=--insecure"
echo %CRDB_COMPOSE% | find /i "labs-b" >nul && (set "NODE=crdbb" & set "HTTP0=8180" & set "SQL0=26357")
echo %CRDB_COMPOSE% | find /i "labs-secure" >nul && (set "NODE=crdbs" & set "HTTP0=8280" & set "SQL0=26457" & set "AUTH=--certs-dir=/certs --host=crdbs1")

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
echo %CRDB_COMPOSE% | find /i "labs-secure" >nul
if not errorlevel 1 (
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
echo Waiting for all nodes to join...
for /l %%i in (1,1,60) do (
    for /f "usebackq delims=" %%n in (`%COMPOSE% exec -T %NODE%1 ./cockroach sql %AUTH% --format^=tsv -e "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;" 2^>nul ^| findstr /r "^[0-9]"`) do (
        if "%%n"=="3" goto :up_ready
    )
    timeout /t 2 /nobreak >nul
)
:up_ready
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
set "N=%~1"
if "%N%"=="" set "N=1"
shift
set "REST="
:sqlon_collect
if "%~1"=="" goto :sqlon_run
set "REST=!REST! %1"
shift
goto :sqlon_collect
:sqlon_run
%COMPOSE% exec %NODE%%N% ./cockroach sql %AUTH%!REST!
goto :done

:stopnode
if "%~1"=="" (echo usage: crdb.bat stop ^<node-number^> & set "RC=1" & goto :done)
%COMPOSE% stop %NODE%%~1
goto :done

:startnode
if "%~1"=="" (echo usage: crdb.bat start ^<node-number^> & set "RC=1" & goto :done)
%COMPOSE% start %NODE%%~1
goto :done

:addnode
%COMPOSE% --profile scale up -d %NODE%4
echo Node 4 started ^(one port above node 3^)
goto :done

:console
echo http://localhost:%HTTP0%  ^(SQL on localhost:%SQL0%^)
goto :done

:logs
set "N=%~1"
if "%N%"=="" set "N=1"
%COMPOSE% logs -f %NODE%%N%
goto :done

:reset
%COMPOSE% --profile scale down -v
call "%~f0" up
goto :done

:help
echo.
for /f "tokens=1,* delims=:" %%a in ('findstr /b /c:"rem " "%~f0"') do echo %%a %%b
echo.
goto :done

:done
popd >nul 2>&1
endlocal & exit /b %RC%
