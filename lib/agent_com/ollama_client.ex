defmodule AgentCom.OllamaClient do
  @moduledoc """
  Stateless HTTP wrapper for Ollama /api/chat endpoint.

  Provides a simple `chat/2` function that sends a POST request to a local
  Ollama instance and returns parsed content with token counts. Used by
  `ClaudeClient` GenServer as the `:ollama` backend alternative to the
  Claude Code CLI.

  ## Configuration

  | Key                   | Default       | Description                    |
  |-----------------------|---------------|--------------------------------|
  | `:ollama_host`        | `"localhost"` | Ollama server hostname         |
  | `:ollama_port`        | `11434`       | Ollama server port             |
  | `:ollama_model`       | `"qwen3:8b"`  | Default model for chat requests|
  | `:ollama_timeout_ms`  | `120_000`     | HTTP request timeout (ms)      |

  ## Usage

      AgentCom.OllamaClient.chat("What is 2+2?")
      AgentCom.OllamaClient.chat("Translate to French", system: "You are a translator")
  """
  require Logger

  @default_host "localhost"
  @default_port 11434
  @default_model "qwen3:8b"
  @default_timeout_ms 120_000

  @doc """
  Send a chat request to Ollama /api/chat.

  ## Parameters

  - `prompt` -- the user message content (string)
  - `opts` -- keyword list of options:
    - `:system` -- system message string (optional)
    - `:model` -- model name override
    - `:host` -- Ollama host override
    - `:port` -- Ollama port override
    - `:timeout` -- HTTP timeout override (ms)
    - `:tools` -- list of tool definitions (optional)

  ## Returns

  - `{:ok, %{content: string, prompt_tokens: integer, eval_tokens: integer, total_duration_ns: integer}}`
  - `{:error, term()}`
  """
  @spec chat(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(prompt, opts \\ []) do
    host = Keyword.get(opts, :host, config(:ollama_host, @default_host))
    port = Keyword.get(opts, :port, config(:ollama_port, @default_port))
    model = Keyword.get(opts, :model, config(:ollama_model, @default_model))
    timeout = Keyword.get(opts, :timeout, config(:ollama_timeout_ms, @default_timeout_ms))
    system = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools)

    Logger.info("ollama_chat_request",
      model: model,
      prompt_bytes: byte_size(prompt)
    )

    messages = build_messages(system, prompt)
    body = build_body(model, messages, tools)
    url = "http://#{host}:#{port}/api/chat"

    case do_post(url, body, timeout) do
      {:ok, response_map} ->
        result = parse_response(response_map)

        case result do
          {:ok, parsed} ->
            Logger.info("ollama_chat_success",
              model: model,
              duration_ns: parsed.total_duration_ns
            )

          {:error, reason} ->
            Logger.info("ollama_chat_parse_error",
              model: model,
              reason: inspect(reason)
            )
        end

        result

      {:error, _} = err ->
        Logger.info("ollama_chat_error",
          model: model,
          error: inspect(err)
        )

        err
    end
  end

  # ---------------------------------------------------------------------------
  # Message and body builders (public for testing)
  # ---------------------------------------------------------------------------

  @doc false
  @spec build_messages(String.t() | nil, String.t()) :: [map()]
  def build_messages(system, prompt) do
    messages =
      if system && system != "" do
        [%{"role" => "system", "content" => system}]
      else
        []
      end

    messages ++ [%{"role" => "user", "content" => prompt}]
  end

  @doc false
  @spec build_body(String.t(), [map()], list() | nil) :: map()
  def build_body(model, messages, tools) do
    base = %{
      "model" => model,
      "messages" => messages,
      "stream" => false,
      "options" => %{"temperature" => 0.3, "num_ctx" => 8192}
    }

    if tools && tools != [] do
      Map.put(base, "tools", tools)
    else
      base
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP POST
  # ---------------------------------------------------------------------------

  defp do_post(url, body, timeout) do
    url_charlist = String.to_charlist(url)
    encoded_body = Jason.encode!(body)
    headers = [{~c"content-type", ~c"application/json"}]
    content_type = ~c"application/json"
    http_opts = [timeout: timeout, connect_timeout: 5_000]

    try do
      case :httpc.request(:post, {url_charlist, headers, content_type, encoded_body}, http_opts, []) do
        {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
          case Jason.decode(to_string(resp_body)) do
            {:ok, decoded} ->
              {:ok, decoded}

            {:error, reason} ->
              {:error, {:json_decode_error, reason}}
          end

        {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
          {:error, {:http_error, status, to_string(resp_body)}}

        {:error, reason} ->
          {:error, {:connection_error, reason}}
      end
    rescue
      e ->
        {:error, {:unexpected_error, Exception.message(e)}}
    end
  end

  # ---------------------------------------------------------------------------
  # Response parsing (public for testing)
  # ---------------------------------------------------------------------------

  @doc false
  @spec parse_response(map()) :: {:ok, map()} | {:error, term()}
  def parse_response(%{"message" => %{"content" => content}} = response) do
    cleaned_content = strip_thinking(content)

    {:ok,
     %{
       content: cleaned_content,
       prompt_tokens: Map.get(response, "prompt_eval_count", 0),
       eval_tokens: Map.get(response, "eval_count", 0),
       total_duration_ns: Map.get(response, "total_duration", 0)
     }}
  end

  def parse_response(response_map) do
    {:error, {:unexpected_format, response_map}}
  end

  @doc false
  @spec strip_thinking(String.t()) :: String.t()
  def strip_thinking(content) do
    Regex.replace(~r/<think>.*?<\/think>/s, content, "") |> String.trim()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp config(key, default), do: Application.get_env(:agent_com, key, default)
end
