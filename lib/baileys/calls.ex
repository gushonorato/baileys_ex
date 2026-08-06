defmodule Baileys.Calls do
  @moduledoc false

  alias Baileys.Binary.{Node, NodeUtils}

  @terminal_statuses [:accept, :reject, :terminate, :timeout]

  def decode(node, now \\ &DateTime.utc_now/0)

  def decode(%Node{tag: "call", attrs: attrs} = node, now) when is_function(now, 0) do
    with %Node{} = info <- first_child(node),
         {:ok, status} <- status(info),
         id when is_binary(id) and id != "" <- info.attrs["call-id"],
         chat_id when is_binary(chat_id) and chat_id != "" <- attrs["from"] do
      call = %{
        id: id,
        chat_id: chat_id,
        from: info.attrs["from"] || info.attrs["call-creator"],
        caller_pn: info.attrs["caller_pn"],
        date: timestamp(attrs["t"], now),
        offline?: Map.has_key?(attrs, "offline"),
        status: status,
        is_video?: nil,
        is_group?: nil,
        group_jid: nil,
        latency_ms: nil
      }

      {:ok, enrich(call, info)}
    else
      nil -> {:error, :missing_call_info}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_call}
    end
  end

  def decode(_node, _now), do: {:error, :invalid_call}

  def offer?(%{status: :offer}), do: true
  def offer?(_call), do: false

  def terminal?(%{status: status}), do: status in @terminal_statuses

  defp first_child(%Node{content: content}) when is_list(content) do
    Enum.find(content, &match?(%Node{}, &1))
  end

  defp first_child(_node), do: nil

  defp status(%Node{tag: tag}) when tag in ["offer", "offer_notice"], do: {:ok, :offer}
  defp status(%Node{tag: "ringing"}), do: {:ok, :ringing}
  defp status(%Node{tag: "preaccept"}), do: {:ok, :preaccept}
  defp status(%Node{tag: "transport"}), do: {:ok, :transport}
  defp status(%Node{tag: "relaylatency"}), do: {:ok, :relay_latency}
  defp status(%Node{tag: "reject"}), do: {:ok, :reject}
  defp status(%Node{tag: "accept"}), do: {:ok, :accept}

  defp status(%Node{tag: "terminate", attrs: %{"reason" => "timeout"}}),
    do: {:ok, :timeout}

  defp status(%Node{tag: "terminate"}), do: {:ok, :terminate}
  defp status(%Node{}), do: {:error, :unsupported_call_status}

  defp enrich(%{status: :offer} = call, info) do
    %{
      call
      | is_video?: not is_nil(NodeUtils.child(info, "video")),
        is_group?: info.attrs["type"] == "group" or is_binary(info.attrs["group-jid"]),
        group_jid: info.attrs["group-jid"]
    }
  end

  defp enrich(%{status: :relay_latency} = call, info) do
    value = info.attrs["latency"] || info.attrs["latency_ms"] || info.attrs["latency-ms"]
    %{call | latency_ms: number(value)}
  end

  defp enrich(call, _info), do: call

  defp timestamp(value, now) do
    with {timestamp, ""} <- Integer.parse(value || ""),
         {:ok, datetime} <- DateTime.from_unix(timestamp) do
      datetime
    else
      _invalid -> now.()
    end
  end

  defp number(value) do
    case Float.parse(value || "") do
      {number, ""} when number == number ->
        if trunc(number) == number, do: trunc(number), else: number

      _invalid ->
        nil
    end
  end
end
