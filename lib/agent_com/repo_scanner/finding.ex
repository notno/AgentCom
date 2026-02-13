defmodule AgentCom.RepoScanner.Finding do
  @moduledoc """
  Struct representing a single sensitive-content finding from a repo scan.

  Each finding captures the location, category, severity, and recommended action
  for a detected pattern match. Token matches are always redacted before being
  stored in `matched_text`.
  """

  @derive Jason.Encoder

  defstruct [
    :file_path,
    :line_number,
    :category,
    :pattern_name,
    :matched_text,
    :severity,
    :replacement,
    :action
  ]

  @type t :: %__MODULE__{
          file_path: String.t(),
          line_number: non_neg_integer(),
          category: :tokens | :ips | :workspace_files | :personal_refs,
          pattern_name: String.t(),
          matched_text: String.t(),
          severity: :critical | :warning,
          replacement: String.t() | nil,
          action: :replace | :remove_and_gitignore
        }
end
