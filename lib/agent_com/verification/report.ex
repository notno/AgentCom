defmodule AgentCom.Verification.Report do
  @moduledoc """
  Builds structured verification reports from check results.

  Pure functions -- no GenServer, no side effects. Reports capture per-check
  pass/fail status with stdout/stderr output, per-check timing, and overall
  status derived from check results using priority ordering:

      :error > :timeout > :fail > :pass

  ## Report Structure

      %{
        task_id: string,
        run_number: integer,
        status: :pass | :fail | :error | :timeout | :skip | :auto_pass,
        started_at: integer (milliseconds),
        duration_ms: integer | nil,
        timeout_ms: integer,
        checks: [check_result],
        summary: %{total, passed, failed, errors, timed_out}
      }

  ## Convenience Constructors

  - `build_skipped/1` -- task opted out with skip_verification: true
  - `build_auto_pass/1` -- task has no verification_steps defined
  - `build_timeout/1` -- global verification timeout fired
  """

  @default_timeout_ms 120_000

  @doc """
  Build a verification report from a list of check results.

  Each check result is a map with keys: `type`, `target`, `description`,
  `status` (:pass | :fail | :error | :timeout), `output`, `duration_ms`.

  Options:
  - `timeout_ms` -- the configured timeout for this run (default #{@default_timeout_ms})
  - `duration_ms` -- total verification run duration
  """
  def build(task_id, run_number, checks, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    duration_ms = Keyword.get(opts, :duration_ms)

    summary = compute_summary(checks)
    status = derive_status(checks)

    %{
      task_id: task_id,
      run_number: run_number,
      status: status,
      started_at: System.system_time(:millisecond),
      duration_ms: duration_ms,
      timeout_ms: timeout_ms,
      checks: checks,
      summary: summary
    }
  end

  @doc """
  Build a report for a task that opted out of verification (skip_verification: true).
  """
  def build_skipped(task_id) do
    empty_report(task_id, :skip)
  end

  @doc """
  Build a report for a task with no verification_steps defined (auto-pass).
  """
  def build_auto_pass(task_id) do
    empty_report(task_id, :auto_pass)
  end

  @doc """
  Build a report for a verification run that timed out globally.
  """
  def build_timeout(task_id) do
    empty_report(task_id, :timeout)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp empty_report(task_id, status) do
    %{
      task_id: task_id,
      run_number: 0,
      status: status,
      started_at: System.system_time(:millisecond),
      duration_ms: nil,
      timeout_ms: @default_timeout_ms,
      checks: [],
      summary: %{total: 0, passed: 0, failed: 0, errors: 0, timed_out: 0}
    }
  end

  defp compute_summary(checks) do
    Enum.reduce(checks, %{total: 0, passed: 0, failed: 0, errors: 0, timed_out: 0}, fn check, acc ->
      acc = %{acc | total: acc.total + 1}

      case check.status do
        :pass -> %{acc | passed: acc.passed + 1}
        :fail -> %{acc | failed: acc.failed + 1}
        :error -> %{acc | errors: acc.errors + 1}
        :timeout -> %{acc | timed_out: acc.timed_out + 1}
        _ -> acc
      end
    end)
  end

  defp derive_status(checks) do
    Enum.reduce(checks, :pass, fn check, current ->
      higher_priority(current, check.status)
    end)
  end

  # Priority: :error > :timeout > :fail > :pass
  defp higher_priority(:error, _), do: :error
  defp higher_priority(_, :error), do: :error
  defp higher_priority(:timeout, _), do: :timeout
  defp higher_priority(_, :timeout), do: :timeout
  defp higher_priority(:fail, _), do: :fail
  defp higher_priority(_, :fail), do: :fail
  defp higher_priority(a, _), do: a
end
