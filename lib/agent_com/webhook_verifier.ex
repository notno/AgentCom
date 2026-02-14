defmodule AgentCom.WebhookVerifier do
  @moduledoc """
  Verifies GitHub webhook HMAC-SHA256 signatures.

  Uses the webhook secret from Config GenServer and compares against
  the X-Hub-Signature-256 header using timing-safe comparison.
  """
  import Plug.Conn

  @doc """
  Verify the GitHub webhook signature on a conn.

  Returns `{:ok, conn}` if signature is valid, `{:error, reason}` otherwise.
  Reasons: :invalid_signature, :missing_signature, :no_secret_configured
  """
  def verify_signature(conn) do
    with [signature_header] <- get_req_header(conn, "x-hub-signature-256"),
         "sha256=" <> received_hex <- signature_header,
         {:ok, secret} <- get_webhook_secret() do
      raw_body = conn.assigns[:raw_body] |> Enum.reverse() |> Enum.join()

      computed_hex =
        :crypto.mac(:hmac, :sha256, secret, raw_body)
        |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(computed_hex, received_hex) do
        {:ok, conn}
      else
        {:error, :invalid_signature}
      end
    else
      [] -> {:error, :missing_signature}
      nil -> {:error, :missing_signature}
      {:error, :no_secret_configured} -> {:error, :no_secret_configured}
      _ -> {:error, :missing_signature}
    end
  end

  defp get_webhook_secret do
    case AgentCom.Config.get(:github_webhook_secret) do
      nil -> {:error, :no_secret_configured}
      secret -> {:ok, secret}
    end
  end
end
