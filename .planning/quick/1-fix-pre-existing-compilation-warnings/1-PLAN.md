---
phase: quick
plan: 1
type: execute
wave: 1
depends_on: []
files_modified:
  - lib/agent_com/analytics.ex
  - lib/agent_com/router.ex
  - lib/agent_com/socket.ex
  - lib/agent_com/endpoint.ex
autonomous: true
must_haves:
  truths:
    - "mix compile --force produces zero warnings"
    - "All existing tests still pass"
  artifacts:
    - path: "lib/agent_com/analytics.ex"
      provides: "Fixed unused var and range step"
    - path: "lib/agent_com/router.ex"
      provides: "Removed dead error clause and unused binding"
    - path: "lib/agent_com/socket.ex"
      provides: "Removed dead error clause on Router.route"
    - path: "lib/agent_com/endpoint.ex"
      provides: "Removed dead error clause and fixed always-true conditional"
  key_links: []
---

<objective>
Fix all 7 pre-existing compilation warnings across 4 files.

Purpose: Clean compiler output so new warnings are immediately visible during ongoing development.
Output: Zero-warning compilation.
</objective>

<execution_context>
@C:/Users/nrosq/.claude/get-shit-done/workflows/execute-plan.md
@C:/Users/nrosq/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Fix analytics.ex warnings (unused var + range step)</name>
  <files>lib/agent_com/analytics.ex</files>
  <action>
Two fixes in analytics.ex:

1. **Line 32 — unused variable `type`:** The parameter `type` in `record_message(from, to, type \\ "chat")` is never used in the function body. Prefix with underscore: `_type \\ "chat"`. Keep the default value so the function signature stays the same for callers.

2. **Line 117 — range needs explicit step:** Change `for i <- 23..0 do` to `for i <- 23..0//-1 do`. This makes the descending range explicit per Elixir 1.12+ requirements.
  </action>
  <verify>mix compile --force 2>&1 | grep -c "analytics.ex" should return 0 (no warnings from this file)</verify>
  <done>analytics.ex compiles with zero warnings; record_message/3 still accepts 2 or 3 args; hourly/1 still returns 24 entries in descending order</done>
</task>

<task type="auto">
  <name>Task 2: Fix router.ex, socket.ex, endpoint.ex dead code and unused bindings</name>
  <files>lib/agent_com/router.ex, lib/agent_com/socket.ex, lib/agent_com/endpoint.ex</files>
  <action>
Five fixes across three files, all related to Router.route/1 always returning `{:ok, _}`:

**router.ex:**

3. **Line 58 — unused variable `result`:** In `send_message/1`, change `{:ok, _} = result ->` to `{:ok, _} ->`. The `result` binding is never used.

4. **Line 63 — dead clause:** Remove `{:error, _} = err -> err` entirely from the case in `send_message/1`. Router.route/1 always returns `{:ok, _}` (all three clauses return `{:ok, :broadcast}`, `{:ok, :delivered}`, or `{:ok, :queued}`). After removing the dead clause, the case has only one branch matching `{:ok, _}`, so simplify the whole function: remove the `case` entirely and just call `route(msg)` then proceed with the analytics/threads tracking. The simplified send_message should be:

    ```elixir
    def send_message(attrs) do
      msg = Message.new(attrs)
      {:ok, _} = route(msg)
      AgentCom.Analytics.record_message(msg.from, msg.to, msg.type)
      AgentCom.Threads.index(msg)
      {:ok, msg}
    end
    ```

**socket.ex:**

5. **Lines 242-243 — dead clause:** In `handle_msg(%{"type" => "message"} = msg, state)`, remove the `{:error, reason} -> reply_error(to_string(reason), state)` clause. After removal, only `{:ok, _}` remains, so simplify: remove the `case` wrapper and just call `Router.route(message)` directly, then build the reply. The simplified block should be:

    ```elixir
    {:ok, _} = Router.route(message)
    reply = Jason.encode!(%{"type" => "message_sent", "id" => message.id})
    {:push, {:text, reply}, state}
    ```

**endpoint.ex:**

6. **Line 114 — dead clause:** In `post "/api/message"`, the `case AgentCom.Router.route(msg) do` block at lines 111-116 has a dead `{:error, reason}` clause. Same fix: remove the case, use pattern match assertion. Replace with:

    ```elixir
    {:ok, _} = AgentCom.Router.route(msg)
    send_json(conn, 200, %{"status" => "sent", "id" => msg.id})
    ```

7. **Line 530 — always-true conditional:** `if agent_id not in @admin_agents do` is always true because `@admin_agents` compiles to `[]` when `ADMIN_AGENTS` env var is unset. The fix: change from compile-time `@admin_agents` module attribute to a runtime check using `Application.get_env` or `System.get_env`. Replace the module attribute at line 521:

    Remove: `@admin_agents (System.get_env("ADMIN_AGENTS", "") |> String.split(",", trim: true))`

    Add a private helper function near the bottom of the module:

    ```elixir
    defp admin_agents do
      System.get_env("ADMIN_AGENTS", "") |> String.split(",", trim: true)
    end
    ```

    Update line 530: `if agent_id not in admin_agents() do`

    This defers evaluation to runtime, eliminating the compile-time always-true warning and also making the admin list dynamic (can change without recompile).
  </action>
  <verify>mix compile --force 2>&1 | grep "warning:" should return empty (zero warnings across all files)</verify>
  <done>All 4 files compile warning-free; mix test passes with no regressions</done>
</task>

</tasks>

<verification>
Run `mix compile --force 2>&1 | grep -c "warning:"` and confirm the result is `0`.
Run `mix test --exclude smoke --exclude skip` and confirm all tests pass.
</verification>

<success_criteria>
- `mix compile --force` produces zero warnings
- All existing tests pass unchanged
- No behavioral changes to any module (purely mechanical fixes)
</success_criteria>

<output>
After completion, create `.planning/quick/1-fix-pre-existing-compilation-warnings/1-SUMMARY.md`
</output>
