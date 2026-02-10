# Ensure :inets is started for :httpc (used by smoke test HTTP helpers)
:inets.start()

# Compile smoke test helper modules (not auto-loaded by ExUnit since they are .ex files)
smoke_helpers = Path.wildcard("test/smoke/helpers/*.ex")

for helper <- Enum.sort(smoke_helpers) do
  Code.require_file(helper)
end

ExUnit.start(exclude: [:skip], capture_log: true)
