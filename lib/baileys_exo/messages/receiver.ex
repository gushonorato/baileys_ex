defmodule BaileysExo.Messages.Receiver do
  @moduledoc false

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.{Node, NodeUtils}
  alias BaileysExo.JID
  alias BaileysExo.Proto.Message

  @nack_unhandled_error "500"

  def context(%Node{attrs: attrs}, %Credentials{me: me}) when is_map(me) do
    with id when is_binary(id) <- attrs["id"],
         from when is_binary(from) <- attrs["from"] do
      from_me = own_jid?(from, me)
      sender = attrs["participant"] || from
      lid_addressed? = attrs["addressing_mode"] == "lid" || String.ends_with?(sender, "@lid")
      sender_alt = if lid_addressed?, do: phone_sender(attrs)
      wire_chat_jid = if from_me, do: attrs["recipient"] || from, else: from
      chat_jid = display_chat_jid(attrs, wire_chat_jid, sender_alt, from_me, lid_addressed?)
      sender_jid = sender_alt || sender

      signal_jid =
        if lid_addressed?,
          do: sender,
          else: attrs["participant_lid"] || attrs["sender_lid"] || sender

      {:ok,
       %{
         id: id,
         chat_jid: chat_jid,
         sender_jid: sender_jid,
         signal_jid: signal_jid,
         from_me: from_me,
         timestamp: parse_integer(attrs["t"]) || System.system_time(:second),
         offline: Map.has_key?(attrs, "offline"),
         receipt_attrs: receipt_attrs(attrs, id, from, wire_chat_jid, from_me)
       }}
    else
      _missing -> {:error, :invalid_message_stanza}
    end
  end

  def context(_node, _credentials), do: {:error, :invalid_message_stanza}

  def receipt_ids(%Node{} = node) do
    item_ids =
      node
      |> NodeUtils.children("list")
      |> Enum.flat_map(&NodeUtils.children(&1, "item"))
      |> Enum.map(& &1.attrs["id"])

    [node.attrs["id"] | item_ids]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  def receipt_ids(_node), do: []

  def receipt_status(nil), do: :delivered
  def receipt_status("sender"), do: :sent
  def receipt_status(type) when type in ["read", "read-self"], do: :read
  def receipt_status("played"), do: :played
  def receipt_status(_type), do: :ignore

  def receipt_timestamp(node, now \\ &DateTime.utc_now/0)

  def receipt_timestamp(%Node{attrs: attrs}, now) when is_function(now, 0) do
    with timestamp when is_integer(timestamp) and timestamp >= 0 <- parse_integer(attrs["t"]),
         {:ok, datetime} <- DateTime.from_unix(timestamp) do
      datetime
    else
      _missing_or_invalid -> now.()
    end
  end

  def receipt_timestamp(_node, now) when is_function(now, 0), do: now.()

  def ack(%Node{tag: tag, attrs: attrs}, %Credentials{me: me}, error \\ nil) when is_map(me) do
    %Node{
      tag: "ack",
      attrs:
        %{
          "id" => attrs["id"],
          "to" => attrs["from"],
          "class" => tag
        }
        |> maybe_put_message_from(tag, me[:id])
        |> maybe_put("error", error)
        |> copy_attr(attrs, "participant")
        |> copy_attr(attrs, "recipient")
        |> copy_attr(attrs, "type")
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
  end

  def failure_ack(node, credentials), do: ack(node, credentials, @nack_unhandled_error)

  def offline_batch_request(%Node{tag: "ib"} = node) do
    if NodeUtils.child(node, "offline_preview") do
      {:ok,
       %Node{
         tag: "ib",
         content: [%Node{tag: "offline_batch", attrs: %{"count" => "100"}}]
       }}
    else
      :ignore
    end
  end

  def offline_batch_request(_node), do: :ignore

  @doc false
  def extract_text(%Message{} = message), do: extract_text(message, 0)

  defp extract_text(%Message{} = message, depth) when depth < 5 do
    text =
      message.conversation ||
        (message.extendedTextMessage && message.extendedTextMessage.text)

    if is_binary(text) do
      {:ok, text}
    else
      message
      |> wrapped_message()
      |> case do
        %Message{} = inner -> extract_text(inner, depth + 1)
        _missing -> :unsupported
      end
    end
  end

  defp extract_text(_message, _depth), do: :unsupported

  defp wrapped_message(message) do
    Enum.find_value(
      [
        message.ephemeralMessage,
        message.viewOnceMessage,
        message.documentWithCaptionMessage,
        message.viewOnceMessageV2,
        message.viewOnceMessageV2Extension,
        message.editedMessage,
        message.associatedChildMessage,
        message.groupStatusMessage,
        message.groupStatusMessageV2
      ],
      &(&1 && &1.message)
    )
  end

  defp receipt_attrs(attrs, id, from, chat_jid, true) do
    %{"id" => id, "to" => from, "recipient" => chat_jid, "type" => "sender"}
    |> maybe_put("participant", attrs["participant"])
  end

  defp receipt_attrs(attrs, id, from, _chat_jid, false = _from_me) do
    %{"id" => id, "to" => from}
    |> maybe_put("participant", attrs["participant"])
  end

  defp phone_sender(attrs) do
    attrs["participant_pn"] || attrs["sender_pn"] || attrs["peer_recipient_pn"]
  end

  defp display_chat_jid(attrs, wire_chat_jid, _sender_alt, true, true) do
    attrs["recipient_pn"] || wire_chat_jid
  end

  defp display_chat_jid(_attrs, _wire_chat_jid, sender_alt, false, true)
       when is_binary(sender_alt),
       do: sender_alt

  defp display_chat_jid(_attrs, wire_chat_jid, _sender_alt, _from_me, _lid_addressed?),
    do: wire_chat_jid

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

  defp maybe_put_message_from(attrs, "message", from), do: maybe_put(attrs, "from", from)
  defp maybe_put_message_from(attrs, _tag, _from), do: attrs

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
