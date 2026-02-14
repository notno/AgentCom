defmodule AgentCom.SelfImprovement.Finding do
  @moduledoc """
  Common finding struct returned by all improvement scanners.

  Each finding captures scan metadata including the source file, severity,
  estimated effort, scanner type, and suggested action. This struct provides
  a uniform interface between scanners (Credo, Dialyzer, deterministic, LLM)
  and the improvement pipeline (ImprovementHistory filtering, GoalBacklog submission).

  The `effort` field supports tiered autonomy (Phase 34): small changes can be
  auto-applied, medium require review, large require human approval.
  """

  @enforce_keys [:file_path, :line_number, :scan_type, :description, :severity, :suggested_action, :effort, :scanner]

  @derive Jason.Encoder

  defstruct [
    :file_path,
    :line_number,
    :scan_type,
    :description,
    :severity,
    :suggested_action,
    :effort,
    :scanner
  ]

  @type t :: %__MODULE__{
          file_path: String.t(),
          line_number: non_neg_integer(),
          scan_type: String.t(),
          description: String.t(),
          severity: String.t(),
          suggested_action: String.t(),
          effort: String.t(),
          scanner: atom()
        }
end
