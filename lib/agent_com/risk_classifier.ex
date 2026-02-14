defmodule AgentCom.RiskClassifier do
  @moduledoc """
  Classifies completed tasks into risk tiers based on actual code changes.
  Pure function module (no GenServer).

  ## Risk Tiers

  - Tier 1 (auto-merge candidate): trivial/standard complexity, <20 lines,
    test-covered, no new files, no config changes
  - Tier 2 (PR for review): complex tasks, new files, API changes, >20 lines
  - Tier 3 (block and escalate): auth code, deployment config, failed verification

  ## Public API

  - `classify/2` -- Classify a completed task based on its metadata and diff data
  """

  alias AgentCom.Config

  @type diff_meta :: %{
          lines_added: non_neg_integer(),
          lines_deleted: non_neg_integer(),
          files_changed: [String.t()],
          files_added: [String.t()],
          tests_exist: boolean()
        }

  @type classification :: %{
          tier: 1 | 2 | 3,
          reasons: [String.t()],
          auto_merge_eligible: boolean(),
          signals: map()
        }

  @doc """
  Classify a completed task based on its metadata and actual diff data.

  Returns `%{tier: 1|2|3, reasons: [...], auto_merge_eligible: bool, signals: map}`.

  ## Examples

      iex> task = %{complexity: %{effective_tier: :trivial}, verification_report: %{status: :pass}}
      iex> diff = %{lines_added: 5, lines_deleted: 2, files_changed: ["lib/foo.ex"], files_added: [], tests_exist: true}
      iex> AgentCom.RiskClassifier.classify(task, diff)
      %{tier: 1, reasons: [...], auto_merge_eligible: false, signals: %{...}}
  """
  @spec classify(task :: map(), diff_meta :: map() | nil) :: classification()
  def classify(task, nil), do: classify(task, %{})

  def classify(task, diff_meta) when is_map(task) and is_map(diff_meta) do
    signals = gather_signals(task, diff_meta)
    tier = compute_tier(signals)
    result = build_result(tier, signals)

    :telemetry.execute(
      [:agent_com, :risk, :classified],
      %{lines_changed: signals.lines_changed, file_count: signals.file_count},
      %{
        tier: tier,
        complexity_tier: signals.complexity_tier,
        protected_paths: length(signals.protected_paths_touched),
        auto_merge_eligible: result.auto_merge_eligible
      }
    )

    result
  end

  # ---------------------------------------------------------------------------
  # Private: Signal Gathering
  # ---------------------------------------------------------------------------

  defp gather_signals(task, diff_meta) do
    complexity_tier = get_complexity_tier(task)
    lines_added = Map.get(diff_meta, :lines_added, 0)
    lines_deleted = Map.get(diff_meta, :lines_deleted, 0)
    lines_changed = lines_added + lines_deleted
    files_changed = Map.get(diff_meta, :files_changed, [])
    files_added = Map.get(diff_meta, :files_added, [])
    tests_exist = Map.get(diff_meta, :tests_exist, false)
    verification_passed = get_verification_status(task)

    protected_paths = Config.get(:risk_tier3_protected_paths)
    auth_paths = Config.get(:risk_tier3_auth_paths)
    all_protected = (protected_paths || []) ++ (auth_paths || [])

    protected_touched =
      Enum.filter(files_changed, fn file ->
        Enum.any?(all_protected, &String.contains?(file, &1))
      end)

    %{
      complexity_tier: complexity_tier,
      lines_changed: lines_changed,
      files_changed: files_changed,
      files_added: files_added,
      new_file_count: length(files_added),
      file_count: length(files_changed),
      tests_exist: tests_exist,
      verification_passed: verification_passed,
      protected_paths_touched: protected_touched
    }
  end

  defp get_complexity_tier(task) do
    case get_in(task, [:complexity, :effective_tier]) do
      nil -> :unknown
      tier -> tier
    end
  end

  # Handle both string and atom keys for verification report
  defp get_verification_status(task) do
    report = Map.get(task, :verification_report) || Map.get(task, "verification_report")

    case report do
      %{status: :pass} -> true
      %{"status" => "pass"} -> true
      %{status: :auto_pass} -> true
      %{"status" => "auto_pass"} -> true
      %{status: :skip} -> true
      %{"status" => "skip"} -> true
      nil -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Tier Computation
  # ---------------------------------------------------------------------------

  defp compute_tier(signals) do
    cond do
      tier3?(signals) -> 3
      tier1?(signals) -> 1
      true -> 2
    end
  end

  defp tier3?(signals) do
    signals.protected_paths_touched != [] or not signals.verification_passed
  end

  defp tier1?(signals) do
    max_lines = Config.get(:risk_tier1_max_lines) || 20
    max_files = Config.get(:risk_tier1_max_files) || 3
    allowed = Config.get(:risk_tier1_allowed_tiers) || [:trivial, :standard]

    signals.complexity_tier in allowed and
      signals.lines_changed < max_lines and
      signals.file_count <= max_files and
      signals.new_file_count == 0 and
      signals.tests_exist and
      signals.verification_passed
  end

  # ---------------------------------------------------------------------------
  # Private: Result Building
  # ---------------------------------------------------------------------------

  defp build_result(tier, signals) do
    %{
      tier: tier,
      reasons: build_reasons(tier, signals),
      auto_merge_eligible: tier == 1 and auto_merge_enabled?(1),
      signals: signals
    }
  end

  defp auto_merge_enabled?(tier) do
    key = String.to_atom("risk_auto_merge_tier#{tier}")
    Config.get(key) == true
  end

  defp build_reasons(1, signals) do
    [
      "complexity: #{signals.complexity_tier}",
      "lines: #{signals.lines_changed}",
      "files: #{signals.file_count}",
      "new files: 0",
      "tests: present",
      "verification: passed"
    ]
  end

  defp build_reasons(2, signals) do
    max_lines = Config.get(:risk_tier1_max_lines) || 20
    max_files = Config.get(:risk_tier1_max_files) || 3
    allowed = Config.get(:risk_tier1_allowed_tiers) || [:trivial, :standard]

    reasons = []
    reasons = if signals.complexity_tier not in allowed, do: ["complexity: #{signals.complexity_tier}" | reasons], else: reasons
    reasons = if signals.lines_changed >= max_lines, do: ["lines: #{signals.lines_changed} (>=#{max_lines})" | reasons], else: reasons
    reasons = if signals.file_count > max_files, do: ["files: #{signals.file_count} (>#{max_files})" | reasons], else: reasons
    reasons = if signals.new_file_count > 0, do: ["new files: #{signals.new_file_count}" | reasons], else: reasons
    reasons = if not signals.tests_exist, do: ["no test coverage" | reasons], else: reasons

    if reasons == [], do: ["default tier for review"], else: Enum.reverse(reasons)
  end

  defp build_reasons(3, signals) do
    reasons = []

    reasons =
      if signals.protected_paths_touched != [],
        do: ["protected paths: #{Enum.join(signals.protected_paths_touched, ", ")}" | reasons],
        else: reasons

    reasons =
      if not signals.verification_passed,
        do: ["verification failed" | reasons],
        else: reasons

    if reasons == [], do: ["escalation required"], else: Enum.reverse(reasons)
  end
end
