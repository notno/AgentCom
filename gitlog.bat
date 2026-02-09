@echo off
cd /d %~dp0
git log --format="%%an | %%s" -10
