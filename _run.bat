@echo off
set "PATH=%PATH%;C:\ProgramData\chocolatey\lib\Elixir\tools\bin;C:\Program Files\Erlang OTP\bin"
cd /d "C:\Users\nrosq\.openclaw\workspace\AgentCom"
mix run --no-halt
