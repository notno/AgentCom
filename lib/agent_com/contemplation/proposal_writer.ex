defmodule AgentCom.Contemplation.ProposalWriter do
  @moduledoc """
  Writes Proposal structs as XML files to `priv/proposals/`.

  Handles file naming (`proposal-{timestamp}-{id}.xml`), directory creation,
  and max-3-per-cycle enforcement.
  """

  alias AgentCom.XML.Schemas.Proposal

  require Logger

  @max_proposals_per_cycle 3
  @proposals_dir "priv/proposals"

  @doc """
  Write a list of proposals to XML files.

  Enforces the max-3-per-cycle limit. Returns `{:ok, written_paths}` with
  the list of file paths that were written.
  """
  @spec write_proposals([Proposal.t()], keyword()) :: {:ok, [String.t()]}
  def write_proposals(proposals, opts \\ []) do
    dir = Keyword.get(opts, :dir, proposals_dir())
    ensure_dir(dir)

    proposals
    |> Enum.take(@max_proposals_per_cycle)
    |> Enum.reduce({:ok, []}, fn proposal, {:ok, paths} ->
      case write_single(proposal, dir) do
        {:ok, path} -> {:ok, [path | paths]}
        {:error, reason} ->
          Logger.warning("proposal_write_failed",
            proposal_id: proposal.id,
            reason: inspect(reason)
          )
          {:ok, paths}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
    end
  end

  @doc """
  Returns the max proposals per cycle limit.
  """
  @spec max_per_cycle() :: pos_integer()
  def max_per_cycle, do: @max_proposals_per_cycle

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp write_single(proposal, dir) do
    timestamp = System.system_time(:millisecond)
    safe_id = sanitize_id(proposal.id)
    filename = "proposal-#{timestamp}-#{safe_id}.xml"
    path = Path.join(dir, filename)

    case AgentCom.XML.encode(proposal) do
      {:ok, xml} ->
        File.write(path, xml)
        {:ok, path}

      {:error, reason} ->
        {:error, {:encode_error, reason}}
    end
  rescue
    e -> {:error, {:write_error, Exception.message(e)}}
  end

  defp sanitize_id(nil), do: "unknown"

  defp sanitize_id(id) do
    id
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
    |> String.slice(0, 50)
  end

  defp ensure_dir(dir) do
    File.mkdir_p!(dir)
  end

  defp proposals_dir do
    Application.get_env(:agent_com, :proposals_dir, @proposals_dir)
  end
end
