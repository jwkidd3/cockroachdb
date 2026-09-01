@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================================
rem  pull_latest.bat - update this course repo from GitHub (Windows)
rem
rem  Usage:
rem     scripts\pull_latest.bat            interactive; asks before touching
rem                                        any local changes you have made
rem     scripts\pull_latest.bat /stash     stash local changes, pull, reapply
rem     scripts\pull_latest.bat /force     DISCARD local edits AND local commits,
rem                                        making your copy match GitHub exactly
rem     scripts\pull_latest.bat /help      show this help
rem
rem  Safe by default: it will not overwrite your work. A fast-forward-only pull
rem  is used, so you never end up in a merge conflict mid-lab.
rem ============================================================================

set "RC=0"
set "MODE=ask"
if /i "%~1"=="/stash" set "MODE=stash"
if /i "%~1"=="/force" set "MODE=force"
if /i "%~1"=="/help"  goto :help
if /i "%~1"=="-h"     goto :help
if /i "%~1"=="--help" goto :help

echo.
echo ============================================================
echo   CockroachDB course - pulling the latest materials
echo ============================================================
echo.

rem ---- git present? ---------------------------------------------------------
git --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] git is not installed, or not on your PATH.
    echo         Install it from https://git-scm.com/download/win and re-run.
    set "RC=1"
    goto :end
)

rem ---- move to the repo root (this script lives in <repo>\scripts) ----------
pushd "%~dp0.." >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Could not switch to the repository folder.
    set "RC=1"
    goto :end
)

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
    echo [ERROR] "%CD%" is not a git repository.
    echo         Clone the course first, for example:
    echo             git clone https://github.com/jwkidd3/cockroachdb.git
    set "RC=1"
    goto :cleanup
)

git remote get-url origin >nul 2>&1
if errorlevel 1 (
    echo [ERROR] This repository has no "origin" remote, so there is nothing to pull from.
    echo         Add one with:
    echo             git remote add origin https://github.com/jwkidd3/cockroachdb.git
    set "RC=1"
    goto :cleanup
)

for /f "delims=" %%i in ('git remote get-url origin') do set "ORIGIN=%%i"
for /f "delims=" %%i in ('git rev-parse --abbrev-ref HEAD') do set "BRANCH=%%i"
for /f "delims=" %%i in ('git rev-parse HEAD') do set "BEFORE=%%i"

if "%BRANCH%"=="HEAD" (
    echo [ERROR] You are on a detached HEAD, not a branch.
    echo         Switch to a branch first:  git checkout main
    set "RC=1"
    goto :cleanup
)

echo   Repository : %CD%
echo   Remote     : %ORIGIN%
echo   Branch     : %BRANCH%
echo.

rem ---- local changes? ------------------------------------------------------
set "DIRTY="
for /f "delims=" %%i in ('git status --porcelain --untracked-files=no') do set "DIRTY=1"

set "STASHED="
if defined DIRTY (
    echo   You have local changes to tracked files:
    echo.
    git status --short --untracked-files=no
    echo.

    if "%MODE%"=="force" goto :do_force
    if "%MODE%"=="stash" goto :do_stash

    echo   How would you like to proceed?
    echo     [S] Stash them, pull, then put them back  ^(recommended^)
    echo     [D] Discard them and match GitHub exactly ^(cannot be undone^)
echo         ^(this also drops any commits you made locally^)
    echo     [C] Cancel
    echo.
    set "ANSWER="
    set /p "ANSWER=  Choose S, D or C: "
    if /i "!ANSWER!"=="S" goto :do_stash
    if /i "!ANSWER!"=="D" goto :do_force
    echo.
    echo   Cancelled. Nothing was changed.
    set "RC=0"
    goto :cleanup
)
goto :fetch

:do_stash
echo   Stashing your local changes...
git stash push --include-untracked --message "pull_latest.bat auto-stash"
if errorlevel 1 (
    echo [ERROR] Could not stash your changes; stopping so nothing is lost.
    set "RC=1"
    goto :cleanup
)
set "STASHED=1"
echo.
goto :fetch

:do_force
echo   Discarding local edits to tracked files...
git reset --hard >nul
if errorlevel 1 (
    echo [ERROR] Could not reset the working tree.
    set "RC=1"
    goto :cleanup
)
echo.
goto :fetch

rem ---- fetch + fast-forward ------------------------------------------------
:fetch
echo   Fetching from GitHub...
git fetch --prune origin
if errorlevel 1 (
    echo.
    echo [ERROR] Could not reach GitHub. Check your network connection,
    echo         then run this script again.
    set "RC=1"
    goto :restore
)

git rev-parse --verify --quiet "origin/%BRANCH%" >nul
if errorlevel 1 (
    echo.
    echo [ERROR] The branch "%BRANCH%" does not exist on the remote.
    echo         Switch to the course branch:  git checkout main
    set "RC=1"
    goto :restore
)

if "%MODE%"=="force" (
    echo   Resetting %BRANCH% to match origin/%BRANCH% exactly...
    git reset --hard "origin/%BRANCH%"
    if errorlevel 1 (
        echo [ERROR] Could not reset to origin/%BRANCH%.
        set "RC=1"
        goto :restore
    )
    goto :summary
)

echo   Updating %BRANCH%...
git merge --ff-only "origin/%BRANCH%"
if errorlevel 1 (
    echo.
    echo [ERROR] Your branch has commits that GitHub does not, so it cannot be
    echo         fast-forwarded. Nothing was changed. To throw your commits away
    echo         and match GitHub exactly, run:
    echo.
    echo             scripts\pull_latest.bat /force
    echo.
    echo         That discards your local commits, so copy anything you want
    echo         to keep out of the folder first.
    echo.
    set "RC=1"
    goto :restore
)

:summary
for /f "delims=" %%i in ('git rev-parse HEAD') do set "AFTER=%%i"

echo.
if "%BEFORE%"=="%AFTER%" (
    echo   Already up to date - no new changes.
) else (
    echo   Updated. New commits:
    echo.
    git log --oneline --no-decorate "%BEFORE%..%AFTER%"
    echo.
    echo   Files changed:
    echo.
    git diff --stat "%BEFORE%" "%AFTER%"
)
set "RC=0"

rem ---- put stashed work back ----------------------------------------------
:restore
if defined STASHED (
    echo.
    echo   Restoring your stashed changes...
    git stash pop
    if errorlevel 1 (
        echo.
        echo [WARNING] Your changes conflicted with the update and are still
        echo           saved in the stash. Review them with:
        echo               git stash list
        echo               git stash show -p stash@{0}
        set "RC=1"
    )
)

:cleanup
popd >nul 2>&1

:end
echo.
if "%RC%"=="0" (
    echo   Done.
) else (
    echo   Finished with problems - see the messages above.
)
echo.

rem Keep the window open when launched by double-click from Explorer.
echo %cmdcmdline% | find /i "%~nx0" >nul
if not errorlevel 1 pause

endlocal & exit /b %RC%

:help
echo.
echo pull_latest.bat - update the CockroachDB course repo from GitHub
echo.
echo   scripts\pull_latest.bat          Ask before touching local changes
echo   scripts\pull_latest.bat /stash   Stash local changes, pull, reapply them
echo   scripts\pull_latest.bat /force   Discard local edits and commits; match GitHub
echo   scripts\pull_latest.bat /help    This message
echo.
echo Always does a fast-forward-only pull, so you cannot land in a merge
echo conflict in the middle of a lab.
echo.
exit /b 0
