defmodule BaileysExo.Messages.Receiver do
  @moduledoc false

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.Node
  alias BaileysExo.JID

  @nack_unhandled_error "500"

  def context(%Node{attrs: attrs}, %Credentials{me: me}) when is_map(me) do
    with id when is_binary(id) <- attrs["id"],
         from when is_binary(from) <- attrs["from"] do
      from_me = own_jid?(from, me)
      chat_jid = if from_me, do: attrs["recipient"] || from, else: from
      sender_jid = attrs["participant"] || from
      signal_jid = attrs["sender_lid"] || sender_jid

      {:ok,
       %{
         id: id,
         chat_jid: chat_jid,
         sender_jid: sender_jid,
         signal_jid: signal_jid,
         from_me: from_me,
         timestamp: parse_integer(attrs["t"]) || System.system_time(:second),
         offline: Map.has_key?(attrs, "offline"),
         receipt_attrs: receipt_attrs(attrs, id, from, chat_jid, from_me)
       }}
    else
      _missing -> {:error, :invalid_message_stanza}
    end
  end

  def context(_node, _credentials), do: {:error, :invalid_message_stanza}

  def ack(%Node{tag: tag, attrs: attrs}, %Credentials{me: me}, error \\ nil) when is_map(me) do
    %Node{
      tag: "ack",
      attrs:
        %{
          "id" => attrs["id"],
          "to" => attrs["from"],
          "class" => tag,
          "from" => me[:id]
        }
        |> maybe_put("error", error)
        |> copy_attr(attrs, "participant")
        |> copy_attr(attrs, "recipient")
        |> copy_attr(attrs, "type")
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
  end

  def failure_ack(node, credentials), do: ack(node, credentials, @nack_unhandled_error)

  defp receipt_attrs(attrs, id, from, chat_jid, true) do
    %{"id" => id, "to" => from, "recipient" => chat_jid, "type" => "sender"}
    |> maybe_put("participant", attrs["participant"])
  end

  defp receipt_attrs(attrs, id, from, _chat_jid, false = _from_me) do
    %{"id" => id, "to" => from}
    |> maybe_put("participant", attrs["participant"])
  end

  defp own_jid?(jid, me) do
    Enum.any?([me[:id], me[:lid]], &same_user?(jid, &1))
  end

  defp same_user?(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, left} <- JID.decode(left),
         {:ok, right} <- JID.decode(right) do
      left.user == right.user and left.server == right.server
    else
      _invalid -> false
    end
  end

  defp same_user?(_left, _right), do: false

  defp copy_attr(target, source, key), do: maybe_put(target, key, source[key])

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_integer(nil), do: nil

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end
end
