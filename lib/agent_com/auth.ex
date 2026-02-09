defmodule AgentCom.Auth do
  @moduledoc """
  Token-based authentication for agent connections.

  Tokens are bound to agent_ids. Stored in a JSON file at
  `priv/tokens.json` (or configured via `:agent_com, :tokens_path`).

  ## Token format

  Tokens are 32-byte hex strings. Each maps to exactly one agent_id.
  """
  use GenServer

  @default_path "priv/tokens.json"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    path = tokens_path()
    File.mkdir_p!(Path.dirname(path))
    tokens = load_tokens(path)
    {:ok, %{path: path, tokens: tokens}}
  end

  @doc "Verify a token. Returns {:ok, agent_id} or :error."
  def verify(token) do
    GenServer.call(__MODULE__, {:verify, token})
  end

  @doc "Generate a token for an agent_id. Returns the token string."
  def generate(agent_id) do
    GenServer.call(__MODULE__, {:generate, agent_id})
  end

  @doc "Revoke all tokens for an agent_id."
  def revoke(agent_id) do
    GenServer.call(__MODULE__, {:revoke, agent_id})
  end

  @doc "List all token → agent_id mappings (tokens truncated for display)."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  # Server callbacks

  @impl true
  def handle_call({:verify, token}, _from, state) do
    result = case Map.get(state.tokens, token) do
      nil -> :error
      agent_id -> {:ok, agent_id}
    end
    {:reply, result, state}
  end

  def handle_call({:generate, agent_id}, _from, state) do
    token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    tokens = Map.put(state.tokens, token, agent_id)
    save_tokens(state.path, tokens)
    {:reply, {:ok, token}, %{state | tokens: tokens}}
  end

  def handle_call({:revoke, agent_id}, _from, state) do
    tokens = state.tokens
      |> Enum.reject(fn {_token, id} -> id == agent_id end)
      |> Map.new()
    save_tokens(state.path, tokens)
    {:reply, :ok, %{state | tokens: tokens}}
  end

  def handle_call(:list, _from, state) do
    entries = state.tokens
      |> Enum.map(fn {token, agent_id} ->
        %{agent_id: agent_id, token_prefix: String.slice(token, 0, 8) <> "..."}
      end)
    {:reply, entries, state}
  end

  # Helpers

  defp tokens_path do
    Application.get_env(:agent_com, :tokens_path, @default_path)
  end

  defp load_tokens(path) do
    case File.read(path) do
      {:ok, data} -> Jason.decode!(data)
      {:error, :enoent} -> %{}
    end
  end

  defp save_tokens(path, tokens) do
    File.write!(path, Jason.encode!(tokens, pretty: true))
  end
end
