defmodule AgentCom.Complexity do
  @moduledoc """
  Heuristic engine for inferring task complexity from content.

  Always runs, even when the submitter provides an explicit tier (locked decision).
  Returns a complexity classification map with both explicit and inferred results
  for observability and disagreement logging.

  ## Tiers

  Four tiers: `:trivial`, `:standard`, `:complex`, `:unknown`.
  `:unknown` gets conservative routing (treated as standard or higher by scheduler).

  ## Signals

  The heuristic uses four signals to classify complexity:
  1. Word count of description (short = trivial, medium = standard, long = complex)
  2. File hint count (0 = trivial signal, 1-3 = standard, 4+ = complex)
  3. Verification step count (0 = trivial signal, 1-3 = standard, 4+ = complex)
  4. Keyword detection (complexity-indicating words in description)

  ## Public API

  - `build/1` -- Full complexity map combining explicit and inferred classifications
  - `infer/1` -- Heuristic inference only, returns `%{tier: atom, confidence: float, signals: map}`
  """

  @valid_explicit_tiers [:trivial, :standard, :complex, :unknown]

  # Signal thresholds
  @word_count_trivial 10
  @word_count_complex 50
  @file_count_trivial 0
  @file_count_standard_max 3
  @verification_count_trivial 0
  @verification_count_standard_max 3

  @complex_keywords ~w(refactor architect migration redesign migrate security overhaul rewrite)
  @trivial_keywords ["fix typo", "update readme", "bump version", "rename", "typo", "format", "lint", "version bump"]

  @doc """
  Build the full complexity map for a task, combining explicit and inferred.

  Takes a task params map (string or atom keys) and returns:

      %{
        effective_tier: atom,
        explicit_tier: atom | nil,
        inferred: %{tier: atom, confidence: float, signals: map},
        source: :explicit | :inferred
      }

  Explicit tier always wins over heuristic inference. Heuristic always runs
  for observability. Emits telemetry when explicit and inferred disagree.
  """
  @spec build(map()) :: map()
  def build(params) when is_map(params) do
    explicit_tier = parse_explicit_tier(params)
    inferred = infer(params)

    effective_tier = if explicit_tier, do: explicit_tier, else: inferred.tier

    # Emit telemetry on disagreement (locked decision: always run heuristic for observability)
    if explicit_tier != nil and explicit_tier != inferred.tier do
      :telemetry.execute(
        [:agent_com, :complexity, :disagreement],
        %{},
        %{
          explicit: explicit_tier,
          inferred_tier: inferred.tier,
          confidence: inferred.confidence
        }
      )
    end

    %{
      effective_tier: effective_tier,
      explicit_tier: explicit_tier,
      inferred: inferred,
      source: if(explicit_tier, do: :explicit, else: :inferred)
    }
  end

  @doc """
  Infer complexity from task content using heuristic signals.

  Returns `%{tier: atom, confidence: float, signals: map}`.
  Confidence is clamped to [0.0, 1.0].
  """
  @spec infer(map()) :: map()
  def infer(params) when is_map(params) do
    signals = gather_signals(params)
    {tier, confidence} = classify(signals)
    %{tier: tier, confidence: clamp(confidence), signals: signals}
  end

  # ---------------------------------------------------------------------------
  # Private: Signal Gathering
  # ---------------------------------------------------------------------------

  defp gather_signals(params) do
    description = get_string(params, :description)
    file_hints = get_list(params, :file_hints)
    verification_steps = get_list(params, :verification_steps)

    %{
      word_count: count_words(description),
      file_count: length(file_hints),
      verification_count: length(verification_steps),
      keywords: detect_keywords(description)
    }
  end

  # ---------------------------------------------------------------------------
  # Private: Classification
  # ---------------------------------------------------------------------------

  defp classify(signals) do
    cond do
      # No signals at all (empty params) -> unknown with 0 confidence
      all_zero?(signals) ->
        {:unknown, 0.0}

      # Keywords are strong signals: complex keywords override other signals
      # (a short sentence can describe complex work like "refactor auth system")
      signals.keywords.complex ->
        # Confidence boosted by supporting signals (files, verification steps)
        supporting =
          (if signals.file_count > @file_count_standard_max, do: 1, else: 0) +
          (if signals.verification_count > @verification_count_standard_max, do: 1, else: 0) +
          (if signals.word_count > @word_count_complex, do: 1, else: 0)

        confidence = 0.7 + supporting * 0.1
        {:complex, confidence}

      # Trivial keywords with no contradicting signals -> trivial
      # Only classify as trivial when there's a positive trivial keyword signal.
      # Short descriptions without trivial keywords are likely natural language
      # tasks that need LLM routing, not shell execution.
      signals.keywords.trivial and signals.file_count <= @file_count_standard_max and
          signals.verification_count <= @verification_count_standard_max ->
        confidence = if signals.word_count < @word_count_trivial, do: 0.9, else: 0.75
        {:trivial, confidence}

      # No keyword matches: use signal scoring but floor at :standard.
      # A short natural-language description with no files/verification is
      # ambiguous, not trivial — it likely needs LLM processing.
      true ->
        scores = score_non_keyword_signals(signals)
        tier = majority_tier(scores)
        # Prevent pure-heuristic classification as trivial without keyword support.
        # Trivial requires a positive signal (trivial keyword or shell_command metadata).
        tier = if tier == :trivial and not signals.keywords.trivial, do: :standard, else: tier
        confidence = agreement_ratio(scores, tier)
        {tier, confidence}
    end
  end

  defp score_non_keyword_signals(signals) do
    # Word count signal
    word_score =
      cond do
        signals.word_count < @word_count_trivial -> :trivial
        signals.word_count > @word_count_complex -> :complex
        true -> :standard
      end

    # File count signal
    file_score =
      cond do
        signals.file_count <= @file_count_trivial -> :trivial
        signals.file_count <= @file_count_standard_max -> :standard
        true -> :complex
      end

    # Verification count signal
    verification_score =
      cond do
        signals.verification_count <= @verification_count_trivial -> :trivial
        signals.verification_count <= @verification_count_standard_max -> :standard
        true -> :complex
      end

    [word_score, file_score, verification_score]
  end

  defp majority_tier(scores) do
    freq = Enum.frequencies(scores)

    # Pick the tier with the most votes
    # Tie-breaking: prefer :standard (conservative default)
    {tier, _count} =
      freq
      |> Enum.sort_by(fn {tier, count} ->
        priority = case tier do
          :standard -> 0
          :complex -> 1
          :trivial -> 2
          _ -> 3
        end
        {-count, priority}
      end)
      |> hd()

    tier
  end

  defp agreement_ratio(scores, tier) do
    total = length(scores)
    matching = Enum.count(scores, &(&1 == tier))
    matching / total
  end

  defp all_zero?(signals) do
    signals.word_count == 0 and
      signals.file_count == 0 and
      signals.verification_count == 0 and
      signals.keywords.complex == false and
      signals.keywords.trivial == false
  end

  # ---------------------------------------------------------------------------
  # Private: Explicit Tier Parsing
  # ---------------------------------------------------------------------------

  defp parse_explicit_tier(params) do
    raw =
      Map.get(params, :complexity_tier, Map.get(params, "complexity_tier", nil))

    case raw do
      nil -> nil
      value when is_binary(value) -> parse_tier_string(value)
      value when is_atom(value) -> if value in @valid_explicit_tiers, do: value, else: nil
      _ -> nil
    end
  end

  defp parse_tier_string(str) do
    case str do
      "trivial" -> :trivial
      "standard" -> :standard
      "complex" -> :complex
      "unknown" -> :unknown
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Helpers
  # ---------------------------------------------------------------------------

  defp get_string(params, key) do
    value = Map.get(params, key, Map.get(params, to_string(key), nil))

    case value do
      v when is_binary(v) -> v
      _ -> ""
    end
  end

  defp get_list(params, key) do
    value = Map.get(params, key, Map.get(params, to_string(key), nil))

    case value do
      v when is_list(v) -> v
      _ -> []
    end
  end

  defp count_words(""), do: 0
  defp count_words(nil), do: 0

  defp count_words(str) when is_binary(str) do
    str
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp detect_keywords(""), do: %{complex: false, trivial: false}
  defp detect_keywords(nil), do: %{complex: false, trivial: false}

  defp detect_keywords(description) when is_binary(description) do
    lower = String.downcase(description)

    %{
      complex: Enum.any?(@complex_keywords, &String.contains?(lower, &1)),
      trivial: Enum.any?(@trivial_keywords, &String.contains?(lower, &1))
    }
  end

  defp clamp(value) when is_number(value) do
    value
    |> max(0.0)
    |> min(1.0)
  end
end
