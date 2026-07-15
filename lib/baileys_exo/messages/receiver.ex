defmodule BaileysExo.Messages.Receiver do
  @moduledoc false

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.{Node, NodeUtils}
  alias BaileysExo.JID
  alias BaileysExo.Proto.{Message, VerifiedNameCertificate}

  @nack_unhandled_error "500"

  def context(node, credentials, now \\ &DateTime.utc_now/0)

  def context(%Node{attrs: attrs} = node, %Credentials{me: me} = credentials, now)
      when is_map(me) and is_function(now, 0) do
    with id when is_binary(id) and id != "" <- attrs["id"],
         from when is_binary(from) and from != "" <- attrs["from"],
         {:ok, identity} <- message_identity(attrs, from, me),
         {:ok, addressing_mode} <- addressing_mode(attrs, attrs["participant"] || from) do
      sender = attrs["participant"] || from
      sender_alt = sender_alt(attrs, addressing_mode)
      recipient_alt = recipient_alt(attrs, addressing_mode)
      group? = identity.type == :group

      key = %{
        remote_jid: identity.chat_jid,
        remote_jid_alt: if(group?, do: nil, else: sender_alt),
        remote_jid_username:
          if(group?,
            do: nil,
            else: attrs["peer_recipient_username"] || attrs["recipient_username"]
          ),
        from_me: identity.from_me,
        id: id,
        participant: attrs["participant"],
        participant_alt: if(group?, do: sender_alt),
        participant_username: if(attrs["participant"], do: attrs["participant_username"]),
        addressing_mode: addressing_mode,
        server_id: if(identity.type == :newsletter, do: attrs["server_id"]),
        view_once?: view_once?(node)
      }

      chat_jid =
        display_chat_jid(
          identity.type,
          identity.chat_jid,
          sender_alt,
          recipient_alt,
          identity.from_me,
          addressing_mode
        )

      signal_jid = signal_jid(addressing_mode, identity.author, sender_alt, credentials)
      response = protocol_response(node, credentials, attrs, id, from, identity)

      {:ok,
       %{
         id: id,
         key: key,
         chat_jid: chat_jid,
         sender_jid: if(addressing_mode == :lid, do: sender_alt || sender, else: sender),
         signal_jid: signal_jid,
         wire_chat_jid: identity.chat_jid,
         wire_sender_jid: identity.author,
         from_me: identity.from_me,
         timestamp: message_timestamp(attrs["t"], now),
         status: if(identity.from_me, do: :server_ack),
         category: attrs["category"],
         push_name: attrs["notify"],
         verified_business_name: verified_business_name(node),
         broadcast: identity.type == :broadcast,
         offline: Map.has_key?(attrs, "offline"),
         retry_count: retry_count(node),
         protocol_response: response,
         receipt_attrs: if(response.tag == "receipt", do: response.attrs)
       }}
    else
      {:error, _reason} = error -> error
      _missing -> {:error, :invalid_message_stanza}
    end
  end

  def context(_node, _credentials, _now), do: {:error, :invalid_message_stanza}

  def envelope(context, %Message{} = content, raw_content) when is_binary(raw_content) do
    %{
      key: context.key,
      content: content,
      raw_content: raw_content,
      timestamp: context.timestamp,
      status: context.status,
      category: context.category,
      push_name: context.push_name,
      verified_business_name: context.verified_business_name,
      broadcast: context.broadcast,
      offline: context.offline,
      retry_count: context.retry_count,
      chat_jid: context.chat_jid,
      sender_jid: context.sender_jid,
      signal_jid: context.signal_jid,
      wire_chat_jid: context.wire_chat_jid,
      wire_sender_jid: context.wire_sender_jid,
      protocol_response: context.protocol_response,
      receipt_attrs: context.receipt_attrs
    }
  end

  def text_metadata(envelope) do
    %{
      id: envelope.key.id,
      chat_jid: envelope.chat_jid,
      sender_jid: envelope.sender_jid,
      from_me: envelope.key.from_me,
      timestamp: envelope.timestamp,
      offline: envelope.offline
    }
  end

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

  def receipt_key(%Node{attrs: attrs}, id, %Credentials{me: me}) do
    from = attrs["from"] || attrs["to"] || ""
    stanza_sender = attrs["participant"] || from
    from_me_node = own_jid?(stanza_sender, me || %{})

    remote_jid =
      if not from_me_node or grouped_jid?(from),
        do: from,
        else: attrs["recipient"] || from

    from_me =
      is_nil(attrs["recipient"]) or
        (attrs["type"] in ["retry", "sender"] and from_me_node)

    sender = attrs["participant"] || remote_jid

    mode =
      case addressing_mode(attrs, sender) do
        {:ok, mode} -> mode
        _error -> :pn
      end

    grouped? = grouped_jid?(remote_jid)

    %{
      remote_jid: remote_jid,
      remote_jid_alt: if(grouped?, do: nil, else: sender_alt(attrs, mode)),
      remote_jid_username: attrs["recipient_username"],
      from_me: from_me,
      id: id,
      participant: attrs["participant"],
      participant_alt: nil,
      participant_username: nil,
      addressing_mode: mode,
      server_id: nil,
      view_once?: false
    }
  end

  def user_receipt?(node, credentials) do
    node |> receipt_key("", credentials) |> Map.fetch!(:remote_jid) |> grouped_jid?()
  end

  def user_receipt(%Node{attrs: %{"participant" => participant}}, status, timestamp)
      when is_binary(participant) and participant != "" do
    base = %{
      user_jid: normalize_user_jid(participant),
      receipt_timestamp: nil,
      read_timestamp: nil,
      played_timestamp: nil,
      pending_device_jids: [],
      delivered_device_jids: []
    }

    case status do
      :read -> %{base | read_timestamp: timestamp}
      :played -> %{base | played_timestamp: timestamp}
      _delivered_or_sent -> %{base | receipt_timestamp: timestamp}
    end
  end

  def user_receipt(_node, _status, _timestamp), do: nil

  defp normalize_user_jid(jid) do
    case JID.decode(jid) do
      {:ok, decoded} -> JID.encode(decoded.user, decoded.server)
      {:error, :invalid_jid} -> jid
    end
  end

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

  def ack(%Node{tag: tag, attrs: attrs}, %Credentials{} = credentials, error \\ nil) do
    me = credentials.me || %{}

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

  defp direct_receipt_attrs(attrs, id, from, chat_jid, true) do
    %{"id" => id, "to" => from, "recipient" => chat_jid, "type" => "sender"}
    |> maybe_put("participant", attrs["participant"])
  end

  defp direct_receipt_attrs(attrs, id, from, _chat_jid, false = _from_me) do
    %{"id" => id, "to" => from}
    |> maybe_put("participant", attrs["participant"])
  end

  defp protocol_response(node, credentials, _attrs, _id, _from, %{type: :newsletter}) do
    ack(node, credentials)
  end

  defp protocol_response(
         _node,
         _credentials,
         %{"category" => "peer"} = attrs,
         id,
         _from,
         %{type: :direct} = identity
       ) do
    receipt =
      %{"id" => id, "to" => identity.chat_jid, "type" => "peer_msg"}
      |> maybe_put("participant", attrs["participant"])

    %Node{tag: "receipt", attrs: receipt}
  end

  defp protocol_response(_node, _credentials, attrs, id, from, %{type: :direct} = identity) do
    receipt = direct_receipt_attrs(attrs, id, from, identity.chat_jid, identity.from_me)
    %Node{tag: "receipt", attrs: maybe_peer_receipt(receipt, attrs)}
  end

  defp protocol_response(_node, _credentials, attrs, id, _from, identity) do
    receipt =
      %{"id" => id, "to" => identity.chat_jid, "participant" => identity.author}
      |> maybe_put("type", if(identity.from_me, do: "sender"))
      |> maybe_peer_receipt(attrs)

    %Node{tag: "receipt", attrs: receipt}
  end

  defp maybe_peer_receipt(receipt, %{"category" => "peer"}),
    do: Map.put(receipt, "type", "peer_msg")

  defp maybe_peer_receipt(receipt, _attrs), do: receipt

  defp message_identity(attrs, from, me) do
    participant = attrs["participant"]

    cond do
      JID.direct?(from) ->
        from_me = own_jid?(from, me)

        if attrs["recipient"] && not from_me && not meta_recipient?(attrs["recipient"]) do
          {:error, :invalid_message_recipient}
        else
          {:ok,
           %{
             type: :direct,
             chat_jid: if(from_me, do: attrs["recipient"] || from, else: from),
             author: from,
             from_me: from_me
           }}
        end

      String.ends_with?(from, "@g.us") ->
        participant_identity(:group, from, participant, me)

      String.ends_with?(from, "@broadcast") ->
        participant_identity(:broadcast, from, participant, me)

      String.ends_with?(from, "@newsletter") ->
        {:ok, %{type: :newsletter, chat_jid: from, author: from, from_me: own_jid?(from, me)}}

      true ->
        {:error, :unsupported_message_source}
    end
  end

  defp grouped_jid?(jid) do
    String.ends_with?(jid, "@g.us") or String.ends_with?(jid, "@broadcast")
  end

  defp participant_identity(_type, _from, participant, _me)
       when not is_binary(participant) or participant == "",
       do: {:error, :missing_group_participant}

  defp participant_identity(type, from, participant, me) do
    {:ok,
     %{
       type: type,
       chat_jid: from,
       author: participant,
       from_me: own_jid?(participant, me)
     }}
  end

  defp addressing_mode(%{"addressing_mode" => "lid"}, _sender), do: {:ok, :lid}
  defp addressing_mode(%{"addressing_mode" => "pn"}, _sender), do: {:ok, :pn}

  defp addressing_mode(%{"addressing_mode" => mode}, _sender) when is_binary(mode),
    do: {:error, :invalid_addressing_mode}

  defp addressing_mode(_attrs, sender) do
    if String.ends_with?(sender, "@lid") or String.ends_with?(sender, "@hosted.lid"),
      do: {:ok, :lid},
      else: {:ok, :pn}
  end

  defp sender_alt(attrs, :lid) do
    attrs["participant_pn"] || attrs["sender_pn"] || attrs["peer_recipient_pn"]
  end

  defp sender_alt(attrs, :pn) do
    attrs["participant_lid"] || attrs["sender_lid"] || attrs["peer_recipient_lid"]
  end

  defp recipient_alt(attrs, :lid), do: attrs["recipient_pn"]
  defp recipient_alt(attrs, :pn), do: attrs["recipient_lid"]

  defp display_chat_jid(:direct, wire_chat_jid, sender_alt, recipient_alt, from_me, :lid) do
    if from_me, do: recipient_alt || wire_chat_jid, else: sender_alt || wire_chat_jid
  end

  defp display_chat_jid(_type, wire_chat_jid, _sender_alt, _recipient_alt, _from_me, _mode),
    do: wire_chat_jid

  defp message_timestamp(value, now) do
    with timestamp when is_integer(timestamp) and timestamp >= 0 <- parse_integer(value),
         {:ok, datetime} <- DateTime.from_unix(timestamp) do
      datetime
    else
      _invalid -> now.()
    end
  end

  defp retry_count(node) do
    node
    |> NodeUtils.children("enc")
    |> Enum.find_value(fn encrypted ->
      case parse_integer(encrypted.attrs["count"]) do
        count when is_integer(count) and count >= 0 -> count
        _invalid -> nil
      end
    end)
  end

  defp view_once?(node) do
    match?(%Node{attrs: %{"type" => "view_once"}}, NodeUtils.child(node, "unavailable"))
  end

  defp signal_jid(:lid, author, _sender_alt, _credentials), do: author

  defp signal_jid(:pn, author, sender_alt, _credentials) when is_binary(sender_alt) do
    with {:ok, author} <- JID.decode(author),
         {:ok, sender_alt} <- JID.decode(sender_alt) do
      JID.encode(sender_alt.user, sender_alt.server, author.device || sender_alt.device)
    else
      _invalid -> sender_alt
    end
  end

  defp signal_jid(:pn, author, _sender_alt, credentials) do
    with {:ok, decoded} <- JID.decode(author),
         bare = JID.encode(decoded.user, decoded.server),
         mapped when is_binary(mapped) <- credentials.lid_mappings[bare],
         {:ok, mapped} <- JID.decode(mapped) do
      JID.encode(mapped.user, mapped.server, decoded.device)
    else
      _missing_or_invalid -> author
    end
  end

  defp meta_recipient?(jid), do: String.ends_with?(jid, "@bot")

  defp verified_business_name(node) do
    with %Node{content: content} when is_binary(content) <- NodeUtils.child(node, "verified_name"),
         certificate <- VerifiedNameCertificate.decode(content),
         details when is_binary(details) <- certificate.details do
      details |> VerifiedNameCertificate.Details.decode() |> Map.get(:verifiedName)
    else
      _missing_or_invalid -> nil
    end
  rescue
    _invalid -> nil
  end

  defp own_jid?(jid, me) do
    Enum.any?([me[:id], me[:lid]], &same_account?(jid, &1))
  end

  defp same_account?(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, left} <- JID.decode(left),
         {:ok, right} <- JID.decode(right) do
      left.user == right.user
    else
      _invalid -> false
    end
  end

  defp same_account?(_left, _right), do: false

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
