defmodule Baileys.Messages.Notification do
  @moduledoc false

  alias Baileys.Auth.Credentials
  alias Baileys.Binary.{Node, NodeUtils}
  alias Baileys.JID
  alias Baileys.Messages.Receiver

  def decode(%Node{tag: "notification", attrs: %{"type" => "picture"}} = node, credentials) do
    with %Node{tag: operation} = picture <- first_child(node),
         true <- operation in ["set", "delete"],
         from when is_binary(from) and from != "" <- node.attrs["from"] do
      update = %{
        id: normalize_jid(from),
        img_url: if(operation == "set", do: :changed, else: :removed)
      }

      effects = [{:contacts_update, [update]}]

      effects =
        if String.ends_with?(from, "@g.us") do
          case picture_envelope(node, picture, credentials) do
            {:ok, envelope} -> effects ++ [{:messages_upsert, [envelope], :append, nil}]
            {:error, _reason} -> effects
          end
        else
          effects
        end

      {:ok, effects, credentials}
    else
      _invalid -> {:error, :invalid_picture_notification}
    end
  end

  def decode(
        %Node{tag: "notification", attrs: %{"type" => "account_sync"}} = node,
        %Credentials{} = credentials
      ) do
    case first_child(node) do
      %Node{tag: "blocklist"} = blocklist ->
        effects =
          blocklist
          |> NodeUtils.children("item")
          |> Enum.flat_map(fn item ->
            case item.attrs["jid"] do
              jid when is_binary(jid) and jid != "" ->
                type = if item.attrs["action"] == "block", do: :add, else: :remove
                [{:blocklist_update, %{blocklist: [jid], type: type}}]

              _missing ->
                []
            end
          end)

        {:ok, effects, credentials}

      %Node{tag: "disappearing_mode", attrs: attrs} ->
        with {:ok, expiration} <- integer(attrs["duration"]),
             {:ok, timestamp} <- integer(attrs["t"]) do
          mode = %{
            ephemeral_expiration: expiration,
            ephemeral_setting_timestamp: timestamp
          }

          settings = Map.put(credentials.account_settings, :default_disappearing_mode, mode)
          credentials = %{credentials | account_settings: settings}
          {:ok, [{:settings_update, settings}], credentials}
        else
          _invalid -> {:error, :invalid_disappearing_mode}
        end

      %Node{} ->
        {:ok, [], credentials}

      nil ->
        {:error, :invalid_account_sync_notification}
    end
  end

  def decode(%Node{tag: "notification", attrs: %{"type" => "mediaretry"}} = node, credentials) do
    with %Node{} = rmr <- NodeUtils.child(node, "rmr"),
         id when is_binary(id) and id != "" <- node.attrs["id"],
         remote_jid when is_binary(remote_jid) and remote_jid != "" <- rmr.attrs["jid"] do
      key = %{
        remote_jid: remote_jid,
        remote_jid_alt: nil,
        remote_jid_username: nil,
        from_me: rmr.attrs["from_me"] == "true",
        id: id,
        participant: rmr.attrs["participant"],
        participant_alt: nil,
        participant_username: nil,
        addressing_mode: addressing_mode(rmr.attrs["participant"] || remote_jid),
        server_id: nil,
        view_once?: false
      }

      update = media_update(node, key)
      {:ok, [{:media_update, [update]}], credentials}
    else
      _invalid -> {:error, :invalid_media_retry_notification}
    end
  end

  def decode(
        %Node{tag: "notification", attrs: %{"type" => "privacy_token"}} = node,
        credentials
      ) do
    with %Node{} = tokens <- NodeUtils.child(node, "tokens"),
         storage_jid when is_binary(storage_jid) <- privacy_token_jid(node, credentials) do
      privacy_tokens =
        tokens
        |> NodeUtils.children("token")
        |> Enum.reduce(credentials.privacy_tokens, fn token, stored ->
          with "trusted_contact" <- token.attrs["type"],
               content when is_binary(content) and byte_size(content) > 0 <- token.content,
               {:ok, timestamp} <- integer(token.attrs["t"]),
               current = stored[storage_jid],
               true <- is_nil(current) or timestamp >= current.timestamp do
            Map.put(stored, storage_jid, %{token: content, timestamp: timestamp})
          else
            _invalid -> stored
          end
        end)

      {:ok, [], %{credentials | privacy_tokens: privacy_tokens}}
    else
      _invalid -> {:error, :invalid_privacy_token_notification}
    end
  end

  def decode(%Node{tag: "notification"}, credentials), do: {:ok, [], credentials}
  def decode(_node, _credentials), do: {:error, :invalid_notification}

  defp picture_envelope(node, picture, credentials) do
    participant = picture.attrs["author"] || node.attrs["participant"]
    context_node = put_in(node.attrs["participant"], participant)

    with {:ok, context} <- Receiver.context(context_node, credentials) do
      {:ok,
       %{
         key: context.key,
         content: nil,
         raw_content: nil,
         timestamp: context.timestamp,
         status: context.status,
         category: context.category,
         push_name: context.push_name,
         verified_business_name: nil,
         stub_type: :group_change_icon,
         stub_parameters: if(picture.tag == "set", do: List.wrap(picture.attrs["id"]), else: []),
         broadcast: false,
         offline: Map.has_key?(node.attrs, "offline"),
         retry_count: nil,
         chat_jid: context.chat_jid,
         sender_jid: context.sender_jid,
         signal_jid: context.signal_jid,
         wire_chat_jid: context.wire_chat_jid,
         wire_sender_jid: context.wire_sender_jid,
         protocol_response: nil,
         receipt_attrs: nil
       }}
    end
  end

  defp media_update(node, key) do
    case NodeUtils.child(node, "error") do
      %Node{attrs: attrs} ->
        code = integer_value(attrs["code"])

        %{
          key: key,
          media: nil,
          error: %{code: code, status_code: media_status(code), attrs: attrs}
        }

      nil ->
        encrypt = NodeUtils.child(node, "encrypt")
        ciphertext = child_binary(encrypt, "enc_p")
        iv = child_binary(encrypt, "enc_iv")

        if is_binary(ciphertext) and is_binary(iv) do
          %{key: key, media: %{ciphertext: ciphertext, iv: iv}, error: nil}
        else
          %{
            key: key,
            media: nil,
            error: %{code: nil, status_code: 404, attrs: %{reason: :missing_ciphertext}}
          }
        end
    end
  end

  defp first_child(%Node{content: content}) when is_list(content),
    do: Enum.find(content, &match?(%Node{}, &1))

  defp first_child(_node), do: nil

  defp child_binary(nil, _tag), do: nil

  defp child_binary(node, tag) do
    case NodeUtils.child(node, tag) do
      %Node{content: content} when is_binary(content) -> content
      _missing -> nil
    end
  end

  defp normalize_jid(jid) do
    case JID.decode(jid) do
      {:ok, decoded} -> JID.encode(decoded.user, decoded.server)
      {:error, :invalid_jid} -> jid
    end
  end

  defp addressing_mode(jid) do
    if String.ends_with?(jid, "@lid"), do: :lid, else: :pn
  end

  defp privacy_token_jid(node, credentials) do
    sender_lid = node.attrs["sender_lid"]

    cond do
      is_binary(sender_lid) and String.ends_with?(sender_lid, "@lid") ->
        normalize_jid(sender_lid)

      is_binary(node.attrs["from"]) ->
        from = normalize_jid(node.attrs["from"])
        credentials.lid_mappings[from] || from

      true ->
        nil
    end
  end

  defp integer(value) do
    case Integer.parse(value || "") do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _invalid -> {:error, :invalid_integer}
    end
  end

  defp integer_value(value) do
    case integer(value) do
      {:ok, integer} -> integer
      {:error, _reason} -> nil
    end
  end

  defp media_status(0), do: 418
  defp media_status(1), do: 200
  defp media_status(2), do: 404
  defp media_status(3), do: 412
  defp media_status(_code), do: nil
end
