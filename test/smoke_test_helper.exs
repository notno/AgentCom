# Ensure :inets is started for :httpc
:inets.start()
ExUnit.start(exclude: [:skip], capture_log: true)
