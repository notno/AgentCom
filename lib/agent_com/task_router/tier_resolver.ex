defmodule AgentCom.TaskRouter.TierResolver do
  @moduledoc """
  Resolves task complexity tier to execution target type with fallback chains.

  Pure module with three public functions. Uses pattern matching on effective_tier atom.
  Fallback chains implement the locked decision: one-step max (trivial<->standard<->complex).

  ## Target Types

  - `:trivial` -> `:sidecar` (direct local execution)
  - `:standard` -> `:ollama` (local LLM agent)
  - `:complex` -> `:claude` (Claude API agent)
  - `:unknown` -> `:standard` (conservative default)
  """

  @doc """
  Resolve the effective tier from a task's complexity data.

  Returns one of `:trivial`, `:standard`, or `:complex`.
  Unknown or missing complexity data defaults to `:standard` (conservative).
  """
  @spec resolve(map()) :: :trivial | :standard | :complex
  def resolve(%{complexity: %{effective_tier: :trivial}}), do: :trivial
  def resolve(%{complexity: %{effective_tier: :standard}}), do: :standard
  def resolve(%{complexity: %{effective_tier: :complex}}), do: :complex
  def resolve(%{complexity: %{effective_tier: :unknown}}), do: :standard
  def resolve(%{complexity: nil}), do: :standard
  def resolve(%{complexity: %{}}), do: :standard
  def resolve(_), do: :standard

  @doc """
  Get the next tier up in the fallback chain (escalation).

  Returns the next higher tier, or nil if no further escalation is possible.
  One-step max: trivial->standard->complex->nil.
  """
  @spec fallback_up(:trivial | :standard | :complex) :: :standard | :complex | nil
  def fallback_up(:trivial), do: :standard
  def fallback_up(:standard), do: :complex
  def fallback_up(:complex), do: nil

  @doc """
  Get the next tier down in the fallback chain (de-escalation).

  Returns the next lower tier, or nil if no further de-escalation is possible.
  One-step max: complex->standard->trivial->nil.
  """
  @spec fallback_down(:complex | :standard | :trivial) :: :standard | :trivial | nil
  def fallback_down(:complex), do: :standard
  def fallback_down(:standard), do: :trivial
  def fallback_down(:trivial), do: nil
end
