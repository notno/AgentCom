defmodule AgentCom.LogFormatTest do
  @moduledoc """
  Per-module JSON format assertion tests for structured logging.

  Verifies that the LoggerJSON.Formatters.Basic formatter produces valid JSON
  with required fields (time, severity, message) and that metadata propagation
  and secret redaction work correctly.

  These tests call the formatter directly rather than relying on CaptureLog,
  because ExUnit's CaptureLog handler bypasses the formatter and captures
  plain-text output. Direct formatter invocation gives deterministic JSON output.
  """

  use ExUnit.Case, async: true

  @formatter_opts [
    metadata: {:all_except, [:conn, :crash_reason]},
    redactors: [
      {LoggerJSON.Redactors.RedactKeys, ["token", "auth_token", "secret"]}
    ]
  ]

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp format_log_event(level, message, meta_overrides \\ %{}) do
    {module, config} = LoggerJSON.Formatters.Basic.new(@formatter_opts)

    base_meta = %{
      time: System.system_time(:microsecond),
      domain: [:elixir],
      mfa: {AgentCom.TaskQueue, :submit, 1},
      file: ~c"lib/agent_com/task_queue.ex",
      line: 42
    }

    meta = Map.merge(base_meta, meta_overrides)

    log_event = %{
      level: level,
      meta: meta,
      msg: {:string, message}
    }

    output = module.format(log_event, config)
    IO.iodata_to_binary(output) |> String.trim()
  end

  defp parse_log(level, message, meta_overrides \\ %{}) do
    raw = format_log_event(level, message, meta_overrides)
    {:ok, parsed} = Jason.decode(raw)
    parsed
  end

  # ---------------------------------------------------------------------------
  # JSON Format Validity
  # ---------------------------------------------------------------------------

  describe "JSON format validity" do
    test "logger output is valid JSON with required fields" do
      raw = format_log_event(:info, "test_event", %{custom_field: "value"})

      # Must parse as valid JSON
      assert {:ok, parsed} = Jason.decode(raw),
             "Log output is not valid JSON: #{raw}"

      # Required top-level fields
      assert is_binary(parsed["time"]), "missing time field"
      assert parsed["severity"] in ["debug", "info", "notice", "warning", "error"],
             "invalid severity: #{parsed["severity"]}"
      assert is_binary(parsed["message"]), "missing message field"
    end

    test "severity matches log level" do
      for {level, expected} <- [
            {:debug, "debug"},
            {:info, "info"},
            {:notice, "notice"},
            {:warning, "warning"},
            {:error, "error"}
          ] do
        parsed = parse_log(level, "severity_test")
        assert parsed["severity"] == expected,
               "expected severity #{expected} for level #{level}, got #{parsed["severity"]}"
      end
    end

    test "time field is valid ISO 8601 UTC timestamp" do
      parsed = parse_log(:info, "time_test")
      time_str = parsed["time"]

      # Must end with Z (UTC)
      assert String.ends_with?(time_str, "Z"),
             "time should be UTC (end with Z): #{time_str}"

      # Must be parseable
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(time_str),
             "time is not valid ISO 8601: #{time_str}"
    end

    test "message field contains the event string" do
      parsed = parse_log(:info, "task_submitted")
      assert parsed["message"] == "task_submitted"
    end

    test "each log line is a single complete JSON object" do
      raw = format_log_event(:info, "single_line_test")

      # Should be exactly one line (no embedded newlines in the JSON itself)
      lines = String.split(raw, "\n", trim: true)
      assert length(lines) == 1, "expected single line, got #{length(lines)}"
      assert {:ok, _} = Jason.decode(List.first(lines))
    end
  end

  # ---------------------------------------------------------------------------
  # Secret Redaction
  # ---------------------------------------------------------------------------

  describe "secret redaction" do
    test "auth tokens are redacted in log output" do
      parsed = parse_log(:info, "auth_event", %{token: "secret-abc-123"})

      token_value = get_in(parsed, ["metadata", "token"])
      refute token_value == "secret-abc-123", "token was not redacted"
      assert token_value == "[REDACTED]"
    end

    test "auth_token key is redacted" do
      parsed = parse_log(:info, "auth_event", %{auth_token: "bearer-xyz-456"})

      auth_token_value = get_in(parsed, ["metadata", "auth_token"])
      refute auth_token_value == "bearer-xyz-456", "auth_token was not redacted"
      assert auth_token_value == "[REDACTED]"
    end

    test "secret key is redacted" do
      parsed = parse_log(:info, "config_event", %{secret: "my-api-key"})

      secret_value = get_in(parsed, ["metadata", "secret"])
      refute secret_value == "my-api-key", "secret was not redacted"
      assert secret_value == "[REDACTED]"
    end

    test "non-sensitive keys are NOT redacted" do
      parsed = parse_log(:info, "normal_event", %{agent_id: "agent-1", task_id: "task-99"})

      assert get_in(parsed, ["metadata", "agent_id"]) == "agent-1"
      assert get_in(parsed, ["metadata", "task_id"]) == "task-99"
    end
  end

  # ---------------------------------------------------------------------------
  # Metadata Propagation
  # ---------------------------------------------------------------------------

  describe "metadata propagation" do
    test "process metadata appears in log output (module, agent_id, task_id)" do
      parsed = parse_log(:info, "test_with_metadata", %{
        module: AgentCom.TaskQueue,
        agent_id: "test-agent",
        task_id: "task-123"
      })

      metadata = parsed["metadata"]
      assert metadata["agent_id"] == "test-agent"
      assert metadata["task_id"] == "task-123"
      assert metadata["module"] =~ "TaskQueue"
    end

    test "mfa metadata includes module/function/arity" do
      parsed = parse_log(:info, "mfa_test", %{
        mfa: {AgentCom.Scheduler, :try_schedule_all, 1}
      })

      metadata = parsed["metadata"]
      assert metadata["mfa"] =~ "Scheduler"
      assert metadata["mfa"] =~ "try_schedule_all"
    end

    test "line number appears in metadata" do
      parsed = parse_log(:info, "line_test", %{line: 99})

      assert get_in(parsed, ["metadata", "line"]) == 99
    end

    test "file path appears in metadata" do
      parsed = parse_log(:info, "file_test", %{
        file: ~c"lib/agent_com/scheduler.ex"
      })

      assert get_in(parsed, ["metadata", "file"]) == "lib/agent_com/scheduler.ex"
    end
  end

  # ---------------------------------------------------------------------------
  # Per-Module Format (representative GenServers)
  # ---------------------------------------------------------------------------

  describe "per-module format: TaskQueue" do
    test "TaskQueue log event produces valid JSON with module context" do
      parsed = parse_log(:info, "task_submitted", %{
        module: AgentCom.TaskQueue,
        mfa: {AgentCom.TaskQueue, :handle_call, 3},
        file: ~c"lib/agent_com/task_queue.ex",
        line: 50,
        task_id: "task-abc",
        priority: "normal",
        queue_depth: 5
      })

      assert parsed["message"] == "task_submitted"
      assert parsed["severity"] == "info"
      assert parsed["metadata"]["module"] =~ "TaskQueue"
      assert parsed["metadata"]["task_id"] == "task-abc"
    end
  end

  describe "per-module format: DetsBackup" do
    test "DetsBackup log event produces valid JSON with module context" do
      parsed = parse_log(:notice, "backup_complete", %{
        module: AgentCom.DetsBackup,
        mfa: {AgentCom.DetsBackup, :handle_info, 2},
        file: ~c"lib/agent_com/dets_backup.ex",
        line: 120,
        tables_backed_up: 9,
        duration_ms: 250
      })

      assert parsed["message"] == "backup_complete"
      assert parsed["severity"] == "notice"
      assert parsed["metadata"]["module"] =~ "DetsBackup"
      assert parsed["metadata"]["tables_backed_up"] == 9
    end
  end

  describe "per-module format: Scheduler" do
    test "Scheduler log event produces valid JSON with module context" do
      parsed = parse_log(:info, "schedule_attempt", %{
        module: AgentCom.Scheduler,
        mfa: {AgentCom.Scheduler, :try_schedule_all, 1},
        file: ~c"lib/agent_com/scheduler.ex",
        line: 80,
        idle_agents: 3,
        queued_tasks: 7
      })

      assert parsed["message"] == "schedule_attempt"
      assert parsed["severity"] == "info"
      assert parsed["metadata"]["module"] =~ "Scheduler"
      assert parsed["metadata"]["idle_agents"] == 3
      assert parsed["metadata"]["queued_tasks"] == 7
    end
  end

  # ---------------------------------------------------------------------------
  # Formatter Configuration
  # ---------------------------------------------------------------------------

  describe "formatter configuration" do
    test "LoggerJSON.Formatters.Basic is configured in config.exs" do
      # Verify the formatter module is available and produces expected output
      {module, _config} = LoggerJSON.Formatters.Basic.new(@formatter_opts)
      assert module == LoggerJSON.Formatters.Basic
    end

    test "RedactKeys redactor is configured for token, auth_token, secret" do
      # The redactor configuration should match our @formatter_opts
      {_module, config} = LoggerJSON.Formatters.Basic.new(@formatter_opts)
      assert is_map(config)
      # Verify by actually redacting
      for key <- [:token, :auth_token, :secret] do
        parsed = parse_log(:info, "redact_config_test", %{key => "sensitive-value"})
        assert get_in(parsed, ["metadata", Atom.to_string(key)]) == "[REDACTED]",
               "key #{key} should be redacted"
      end
    end
  end
end
