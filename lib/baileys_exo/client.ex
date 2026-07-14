defmodule BaileysExo.Client do
  @moduledoc false

  use GenServer

  alias Baileys.{
    Account,
    AccountSettings,
    BlocklistUpdate,
    Call,
    Connection,
    ContactUpdate,
    DefaultDisappearingMode,
    Disconnected,
    Error,
    GroupJoinRequest,
    GroupMetadata,
    GroupParticipant,
    GroupParticipantsUpdate,
    GroupUpdate,
    Message,
    MessageKey,
    MessageReaction,
    MessageReceiptUpdate,
    MessageStatus,
    MessageUpdate,
    MediaRetryData,
    MediaRetryError,
    MediaUpdate,
    MessagesUpsert,
    QR,
    TextMessage,
    UserReceipt
  }

  alias BaileysExo.ConnectionProcess
  alias BaileysExo.Messages.Sender
  alias BaileysExo.Store.File, as: FileStore

  def start_link(options) do
    options = Keyword.put_new(options, :owner, self())
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  def connect(client), do: GenServer.call(client, :connect, 30_000)
  def disconnect(client), do: GenServer.call(client, :disconnect, 30_000)
  def logout(client), do: GenServer.call(client, :logout, 30_000)

  def request_pairing_code(client, phone, options) do
    GenServer.call(client, {:pairing_code, phone, options}, 30_000)
  end

  def send_text(client, recipient, text, options) do
    GenServer.call(client, {:send_text, recipient, text, options}, 30_000)
  end

  def status(client), do: GenServer.call(client, :status)
  def subscribe(client, subscriber), do: GenServer.call(client, {:subscribe, subscriber})
  def unsubscribe(client, subscriber), do: GenServer.call(client, {:unsubscribe, subscriber})

  @doc false
  def public_message(envelope) do
    %Message{
      key: public_key(envelope.key),
      content: envelope.content,
      raw_content: envelope.raw_content,
      timestamp: envelope.timestamp,
      status: envelope.status,
      category: envelope.category,
      push_name: envelope.push_name,
      verified_business_name: envelope.verified_business_name,
      stub_type: Map.get(envelope, :stub_type),
      stub_parameters: Map.get(envelope, :stub_parameters, []),
      broadcast?: envelope.broadcast,
      offline?: envelope.offline,
      retry_count: envelope.retry_count
    }
  end

  @impl true
  def init(options) do
    session = Keyword.get(options, :session, "default")
    sessions_path = Keyword.get(options, :sessions_path)

    with :ok <- validate_session(session),
         {:ok, credentials, session_path} <- FileStore.load_or_create(sessions_path, session) do
      owner = Keyword.fetch!(options, :owner)

      {:ok,
       %{
         owner: owner,
         subscribers: add_subscriber(%{}, owner),
         status: :disconnected,
         connection: nil,
         connection_monitor: nil,
         credentials: credentials,
         session_path: session_path,
         options: options
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:baileys_command, :connect}, from, state),
    do: handle_call(:connect, from, state)

  def handle_call({:baileys_command, :disconnect}, from, state),
    do: handle_call(:disconnect, from, state)

  def handle_call({:baileys_command, :logout}, from, state), do: handle_call(:logout, from, state)

  def handle_call({:baileys_command, {:pairing_code, phone, options}}, from, state),
    do: handle_call({:pairing_code, phone, options}, from, state)

  def handle_call({:baileys_command, {:send_text, recipient, text, options}}, from, state),
    do: handle_call({:send_text, recipient, text, options}, from, state)

  def handle_call({:baileys_command, :status}, from, state), do: handle_call(:status, from, state)

  def handle_call({:baileys_command, {:subscribe, subscriber}}, from, state),
    do: handle_call({:subscribe, subscriber}, from, state)

  def handle_call({:baileys_command, {:unsubscribe, subscriber}}, from, state),
    do: handle_call({:unsubscribe, subscriber}, from, state)

  def handle_call(:connect, _from, %{connection: connection} = state)
      when is_pid(connection) do
    if Process.alive?(connection) do
      {:reply, :ok, state}
    else
      start_connection(%{state | connection: nil, connection_monitor: nil})
    end
  end

  def handle_call(:connect, _from, state), do: start_connection(state)

  def handle_call(:disconnect, _from, %{connection: nil} = state) do
    {:reply, :ok, %{state | status: :disconnected}}
  end

  def handle_call(:disconnect, _from, state) do
    Process.demonitor(state.connection_monitor, [:flush])

    if Process.alive?(state.connection) do
      try do
        ConnectionProcess.close(state.connection)
      catch
        :exit, _reason -> :ok
      end
    end

    {:reply, :ok, %{state | connection: nil, connection_monitor: nil, status: :disconnected}}
  end

  def handle_call(
        :logout,
        _from,
        %{connection: connection, credentials: %{me: %{id: jid}}} = state
      )
      when is_pid(connection) do
    case ConnectionProcess.logout(connection, jid) do
      {:ok, _reply} ->
        Process.demonitor(state.connection_monitor, [:flush])
        ConnectionProcess.close(connection)

        with :ok <- FileStore.reset(state.session_path),
             {:ok, credentials, session_path} <-
               FileStore.load_or_create(
                 Path.dirname(state.session_path),
                 Path.basename(state.session_path, ".json")
               ) do
          {:reply, :ok,
           %{
             state
             | connection: nil,
               connection_monitor: nil,
               credentials: credentials,
               session_path: session_path,
               status: :disconnected
           }}
        else
          {:error, reason} -> {:reply, {:error, {:store, reason}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  catch
    :exit, _reason -> {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:logout, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:pairing_code, phone, options}, _from, %{connection: connection} = state)
      when is_pid(connection) do
    custom_code = Keyword.get(options, :custom_code)
    {:reply, ConnectionProcess.request_pairing_code(connection, phone, custom_code), state}
  catch
    :exit, _reason -> {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:pairing_code, _phone, _options}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:send_text, recipient, text, _options}, _from, %{status: :online} = state) do
    case Sender.send_text(state.connection, state.credentials, recipient, text) do
      {:ok, sent, credentials} ->
        {:reply, {:ok, sent}, %{state | credentials: credentials}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_text, _recipient, _text, _options}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:subscribe, subscriber}, _from, state) when is_pid(subscriber) do
    {:reply, :ok, %{state | subscribers: add_subscriber(state.subscribers, subscriber)}}
  end

  def handle_call({:unsubscribe, subscriber}, _from, state) when is_pid(subscriber) do
    {:reply, :ok, %{state | subscribers: remove_subscriber(state.subscribers, subscriber)}}
  end

  @impl true
  def handle_info({:connection_event, {:connection, status}}, state) do
    notify(state, {:connection, %Connection{state: status}})
    {:noreply, %{state | status: status}}
  end

  def handle_info({:connection_event, {:qr, payload}}, state) do
    qr = %QR{payload: payload, expires_at: DateTime.add(DateTime.utc_now(), 60, :second)}
    notify(state, {:qr, qr})
    {:noreply, %{state | status: :awaiting_pairing}}
  end

  def handle_info({:connection_event, {:credentials, credentials}}, state) do
    {:noreply, %{state | credentials: credentials}}
  end

  def handle_info({:connection_event, {:paired, me}}, state) do
    notify(state, {:paired, %Account{jid: me.id, name: me[:name]}})
    {:noreply, %{state | status: :restarting}}
  end

  def handle_info({:connection_event, {:call, calls}}, state) do
    notify(state, {:call, Enum.map(calls, &struct!(Call, &1))})
    {:noreply, state}
  end

  def handle_info({:connection_event, {:contacts_update, updates}}, state) do
    notify(state, {:contacts_update, Enum.map(updates, &struct!(ContactUpdate, &1))})
    {:noreply, state}
  end

  def handle_info({:connection_event, {:blocklist_update, update}}, state) do
    notify(state, {:blocklist_update, struct!(BlocklistUpdate, update)})
    {:noreply, state}
  end

  def handle_info({:connection_event, {:settings_update, settings}}, state) do
    mode =
      case settings[:default_disappearing_mode] do
        nil -> nil
        mode -> struct!(DefaultDisappearingMode, mode)
      end

    notify(state, {:settings_update, %AccountSettings{default_disappearing_mode: mode}})
    {:noreply, state}
  end

  def handle_info({:connection_event, {:messages_media_update, updates}}, state) do
    updates =
      Enum.map(updates, fn update ->
        media = if update.media, do: struct!(MediaRetryData, update.media)
        error = if update.error, do: struct!(MediaRetryError, update.error)
        %MediaUpdate{key: public_key(update.key), media: media, error: error}
      end)

    notify(state, {:messages_media_update, updates})
    {:noreply, state}
  end

  def handle_info({:connection_event, {:text_message, metadata, text}}, state) do
    message = %TextMessage{
      id: metadata.id,
      chat_jid: metadata.chat_jid,
      sender_jid: metadata.sender_jid,
      from_me: metadata.from_me,
      text: text,
      timestamp: message_timestamp(metadata.timestamp),
      offline?: metadata.offline
    }

    notify(state, {:text_message, message})
    {:noreply, state}
  end

  def handle_info(
        {:connection_event, {:messages_upsert, envelopes, type, request_id}},
        state
      ) do
    messages = Enum.map(envelopes, &public_message/1)

    upsert = %MessagesUpsert{
      messages: messages,
      type: type,
      request_id: request_id
    }

    notify(state, {:messages_upsert, upsert})
    project_specialized_message_events(state, messages)
    {:noreply, state}
  end

  def handle_info({:connection_event, {:messages_update, updates}}, state) do
    updates =
      Enum.map(updates, fn update ->
        %MessageUpdate{key: public_key(update.key), update: update.update}
      end)

    notify(state, {:messages_update, updates})
    {:noreply, state}
  end

  def handle_info({:connection_event, {:message_receipt_update, updates}}, state) do
    updates =
      Enum.map(updates, fn update ->
        %MessageReceiptUpdate{
          key: public_key(update.key),
          receipt: struct!(UserReceipt, update.receipt)
        }
      end)

    notify(state, {:message_receipt_update, updates})
    {:noreply, state}
  end

  def handle_info({:connection_event, {:group_effect, {type, payload}}}, state) do
    notify(state, {type, public_group_effect(type, payload)})
    {:noreply, state}
  end

  def handle_info({:connection_event, {:message_status, id, to, status, at, error}}, state) do
    notify(state, {
      :message_status,
      %MessageStatus{id: id, to: to, status: status, at: at, error: error}
    })

    {:noreply, state}
  end

  def handle_info({:connection_event, {:error, reason}}, state) do
    notify(state, {:error, %Error{message: inspect(reason)}})
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, reference, :process, connection, reason},
        %{connection: connection, connection_monitor: reference} = state
      ) do
    if reason not in [:normal, :shutdown] do
      notify(state, {:error, %Error{message: "connection exited: #{inspect(reason)}"}})
    end

    restart? = state.status == :restarting
    disconnect_reason = if restart?, do: :restart_required, else: :connection_closed
    notify(state, {:disconnected, %Disconnected{reason: disconnect_reason}})
    state = %{state | connection: nil, connection_monitor: nil, status: :disconnected}
    if restart?, do: Process.send_after(self(), :reconnect, 500)
    {:noreply, state}
  end

  def handle_info({:DOWN, reference, :process, subscriber, _reason}, state) do
    subscribers =
      case state.subscribers do
        %{^subscriber => ^reference} -> Map.delete(state.subscribers, subscriber)
        _subscribers -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(:reconnect, %{connection: nil} = state) do
    case start_connection_state(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        notify(state, {:error, %Error{message: "reconnect failed: #{inspect(reason)}"}})
        {:noreply, state}
    end
  end

  def handle_info(:reconnect, state), do: {:noreply, state}

  defp start_connection(state) do
    case start_connection_state(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp start_connection_state(state) do
    connection_options = Keyword.put(state.options, :session_path, state.session_path)

    case ConnectionProcess.start_link(self(), state.credentials, connection_options) do
      {:ok, connection} ->
        Process.unlink(connection)
        monitor = Process.monitor(connection)

        {:ok, %{state | connection: connection, connection_monitor: monitor, status: :connecting}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_session(session)
       when is_binary(session) and byte_size(session) > 0 and byte_size(session) <= 64 do
    if Regex.match?(~r/^[a-zA-Z0-9_-]+$/, session), do: :ok, else: {:error, :invalid_session}
  end

  defp validate_session(_session), do: {:error, :invalid_session}

  defp message_timestamp(%DateTime{} = timestamp), do: timestamp
  defp message_timestamp(timestamp), do: DateTime.from_unix!(timestamp)

  defp public_key(%MessageKey{} = key), do: key
  defp public_key(key) when is_map(key), do: struct!(MessageKey, key)

  defp public_target_key(%BaileysExo.Proto.MessageKey{} = key, fallback, from_me, participant) do
    %MessageKey{
      remote_jid: key.remoteJid || fallback.remote_jid,
      remote_jid_alt: fallback.remote_jid_alt,
      remote_jid_username: fallback.remote_jid_username,
      from_me: from_me,
      id: key.id,
      participant: participant,
      participant_alt: fallback.participant_alt,
      participant_username: fallback.participant_username,
      addressing_mode: fallback.addressing_mode,
      server_id: fallback.server_id,
      view_once?: false
    }
  end

  defp project_specialized_message_events(state, messages) do
    me =
      case Map.get(state, :credentials) do
        %{me: me} -> me
        _missing -> nil
      end

    reactions = Enum.flat_map(messages, &message_reaction(&1, me))
    updates = Enum.flat_map(messages, &protocol_update/1)

    if reactions != [], do: notify(state, {:messages_reaction, reactions})
    if updates != [], do: notify(state, {:messages_update, updates})
  end

  defp message_reaction(%Message{} = message, me) do
    case normalized_content(message.content) do
      %BaileysExo.Proto.Message{reactionMessage: reaction}
      when not is_nil(reaction) and not is_nil(reaction.key) ->
        [
          %MessageReaction{
            target_key: reaction_target_key(reaction.key, message.key, me),
            reaction: message
          }
        ]

      _other ->
        []
    end
  end

  defp message_reaction(_message, _me), do: []

  defp protocol_update(%Message{} = message) do
    case normalized_content(message.content) do
      %BaileysExo.Proto.Message{protocolMessage: protocol}
      when not is_nil(protocol) and not is_nil(protocol.key) ->
        build_protocol_update(protocol, message)

      _other ->
        []
    end
  end

  defp protocol_update(_message), do: []

  defp build_protocol_update(protocol, message) do
    target_key = %{message.key | id: protocol.key.id || message.key.id}

    case protocol.type do
      :REVOKE ->
        [
          %MessageUpdate{
            key: target_key,
            update: %{deleted?: true, message: nil, timestamp: message.timestamp}
          }
        ]

      :MESSAGE_EDIT ->
        timestamp = millisecond_timestamp(protocol.timestampMs) || message.timestamp

        [
          %MessageUpdate{
            key: target_key,
            update: %{edited?: true, message: protocol.editedMessage, timestamp: timestamp}
          }
        ]

      _other ->
        []
    end
  end

  defp reaction_target_key(key, %MessageKey{from_me: false} = fallback, me) do
    embedded_from_me = key.fromMe == true

    from_me =
      if embedded_from_me,
        do: false,
        else: own_jid?(key.participant || key.remoteJid, me)

    participant = key.participant || fallback.participant
    key = %{key | remoteJid: fallback.remote_jid}
    public_target_key(key, fallback, from_me, participant)
  end

  defp reaction_target_key(key, fallback, _me) do
    public_target_key(key, fallback, key.fromMe == true, key.participant)
  end

  defp normalized_content(%BaileysExo.Proto.Message{} = content),
    do: normalized_content(content, 0)

  defp normalized_content(content), do: content

  defp normalized_content(%BaileysExo.Proto.Message{} = content, depth) when depth < 8 do
    inner =
      (content.deviceSentMessage && content.deviceSentMessage.message) ||
        Enum.find_value(
          [
            content.ephemeralMessage,
            content.viewOnceMessage,
            content.documentWithCaptionMessage,
            content.viewOnceMessageV2,
            content.viewOnceMessageV2Extension,
            content.editedMessage,
            content.associatedChildMessage,
            content.groupStatusMessage,
            content.groupStatusMessageV2
          ],
          &(&1 && &1.message)
        )

    if inner, do: normalized_content(inner, depth + 1), else: content
  end

  defp normalized_content(content, _depth), do: content

  defp own_jid?(jid, me) when is_binary(jid) and is_map(me) do
    Enum.any?([me[:id], me[:lid]], fn own ->
      with {:ok, left} <- BaileysExo.JID.decode(jid),
           {:ok, right} <- BaileysExo.JID.decode(own) do
        left.user == right.user
      else
        _invalid -> false
      end
    end)
  end

  defp own_jid?(_jid, _me), do: false

  defp millisecond_timestamp(timestamp) when is_integer(timestamp) do
    case DateTime.from_unix(timestamp, :millisecond) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp millisecond_timestamp(_timestamp), do: nil

  defp public_group_effect(:groups_upsert, groups) do
    Enum.map(groups, fn group ->
      group =
        Map.update(
          group,
          :participants,
          [],
          &Enum.map(&1, fn participant -> struct!(GroupParticipant, participant) end)
        )

      struct!(GroupMetadata, group)
    end)
  end

  defp public_group_effect(:groups_update, groups),
    do: Enum.map(groups, &struct!(GroupUpdate, &1))

  defp public_group_effect(:group_participants_update, update) do
    participants = Enum.map(update.participants, &struct!(GroupParticipant, &1))
    struct!(GroupParticipantsUpdate, %{update | participants: participants})
  end

  defp public_group_effect(:group_join_request, update), do: struct!(GroupJoinRequest, update)

  defp notify(state, event) do
    client = self()

    Enum.each(state.subscribers, fn {subscriber, _monitor} ->
      send(subscriber, {:baileys, client, event})
    end)
  end

  defp add_subscriber(subscribers, subscriber) do
    Map.put_new_lazy(subscribers, subscriber, fn -> Process.monitor(subscriber) end)
  end

  defp remove_subscriber(subscribers, subscriber) do
    case Map.pop(subscribers, subscriber) do
      {nil, subscribers} ->
        subscribers

      {reference, subscribers} ->
        Process.demonitor(reference, [:flush])
        subscribers
    end
  end
end
