@echo off
set "PATH=%PATH%;C:\ProgramData\chocolatey\lib\Elixir\tools\bin;C:\Program Files\Erlang OTP\bin"
set "PORT=4000"
cd /d "%~dp0"
mix run --no-halt
