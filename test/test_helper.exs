# Ensure :inets is started for :httpc (used by smoke test HTTP helpers)
:inets.start()

# Compile smoke test helper modules (not auto-loaded by ExUnit since they are .ex files)
smoke_helpers = Path.wildcard("test/smoke/helpers/*.ex")

for helper <- Enum.sort(smoke_helpers) do
  Code.require_file(helper)
end

# Compile test support modules (DETS helpers, test factory, WS client)
support_helpers = Path.wildcard("test/support/*.ex")

for helper <- Enum.sort(support_helpers) do
  Code.require_file(helper)
end

ExUnit.start(exclude: [:skip, :smoke], capture_log: true)
