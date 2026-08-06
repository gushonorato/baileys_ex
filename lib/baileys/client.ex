defmodule Baileys.Client do
  @moduledoc false

  use GenServer

  alias Baileys.{
    Account,
    AccountSettings,
    AppStateMutation,
    AppStateEffect,
    BlocklistUpdate,
    Call,
    Connection,
    ContactUpdate,
    DefaultDisappearingMode,
    DisconnectReason,
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
    MessagingHistoryStatus,
    MessagesUpsert,
    QR,
    TextMessage,
    UserReceipt
  }

  alias Baileys.ConnectionProcess
  alias Baileys.HistorySync
  alias Baileys.Media.Download
  alias Baileys.Messages.Sender
  alias Baileys.Store

  def start_link(options) do
    options = Keyword.put_new(options, :owner, self())
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  def start(options) do
    options = Keyword.put_new(options, :owner, self())
    GenServer.start(__MODULE__, options, Keyword.take(options, [:name]))
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
      raw_payloads: Map.get(envelope, :raw_payloads, List.wrap(envelope.raw_content)),
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

    with :ok <- validate_session(session),
         {:ok, store_config} <- fetch_store(options),
         {:ok, credentials, store} <- Store.open(store_config, session) do
      owner = Keyword.fetch!(options, :owner)

      {:ok,
       %{
         owner: owner,
         subscribers: add_subscriber(%{}, owner),
         status: :disconnected,
         connection: nil,
         connection_monitor: nil,
         credentials: credentials,
         store: store,
         options: options,
         history_queue: pending_history_queue(credentials),
         history_worker: nil,
         history_pause_timer: nil,
         history_completed: MapSet.new(),
         history_retries: %{}
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
    {:reply, :ok, state |> cancel_history_pause() |> Map.put(:status, :disconnected)}
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

    state = cancel_history_pause(state)
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

        state =
          state
          |> cancel_history_pause()
          |> stop_history_worker()

        with {:ok, credentials} <- Store.reset(state.store) do
          {:reply, :ok,
           %{
             state
             | connection: nil,
               connection_monitor: nil,
               credentials: credentials,
               status: :disconnected,
               history_queue: :queue.new(),
               history_worker: nil,
               history_pause_timer: nil,
               history_completed: MapSet.new(),
               history_retries: %{}
           }}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
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
    state = %{state | status: status}

    state =
      if status == :online and is_nil(Map.get(state, :history_worker)) do
        state
        |> Map.put(:history_queue, pending_history_queue(state.credentials))
        |> start_next_history()
      else
        state
      end

    {:noreply, state}
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

  def handle_info({:connection_event, {:app_state_mutations, mutations}}, state) do
    notify(state, {:app_state_mutations, Enum.map(mutations, &struct!(AppStateMutation, &1))})
    {:noreply, state}
  end

  def handle_info({:connection_event, {:app_state_effects, effects}}, state) do
    effects =
      Enum.map(effects, fn effect ->
        mutation = struct!(AppStateMutation, effect.data)
        %AppStateEffect{type: effect.type, data: mutation}
      end)

    notify(state, {:app_state_effects, effects})
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
    {:noreply, enqueue_history(envelopes, state)}
  end

  def handle_info(
        {:history_result, reference, result},
        %{history_worker: {reference, notification, _worker, monitor}} = state
      ) do
    Process.demonitor(monitor, [:flush])
    state = %{state | history_worker: nil}

    state =
      case result do
        {:ok, history} ->
          history = %{history | latest?: history_latest?(history, state)}
          mappings = Enum.map(history.lid_pn_mappings, &%{lid: &1.lid, pn: &1.pn})
          tokens = history_privacy_tokens(history, mappings, state)

          case commit_history(state, mappings, tokens, history, notification) do
            :ok ->
              notify(state, {:messaging_history_set, history})
              update_history_status(history, state)

            {:error, reason} ->
              notify(state, {:error, %Error{message: inspect({:history_persist_failed, reason})}})
              retry_history(notification, state)
          end

        {:error, reason} ->
          notify(state, {:error, %Error{message: inspect({:history_sync_failed, reason})}})
          retry_history(notification, state)
      end

    {:noreply, start_next_history(state)}
  end

  def handle_info({:history_result, _reference, _result}, state), do: {:noreply, state}

  def handle_info(
        {:history_pause, sync_type, token},
        %{history_pause_timer: {_timer, token}} = state
      ) do
    completed = Map.get(state, :history_completed, MapSet.new())

    if not MapSet.member?(completed, sync_type) do
      notify(state, {
        :messaging_history_status,
        %MessagingHistoryStatus{sync_type: sync_type, status: :paused, explicit?: false}
      })
    end

    {:noreply, %{state | history_pause_timer: nil}}
  end

  def handle_info({:history_pause, _sync_type, _token}, state), do: {:noreply, state}

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
        {:DOWN, monitor, :process, worker, reason},
        %{history_worker: {_reference, notification, worker, monitor}} = state
      ) do
    state = %{state | history_worker: nil}
    notify(state, {:error, %Error{message: inspect({:history_worker_failed, reason})}})
    state = retry_history(notification, state)
    {:noreply, start_next_history(state)}
  end

  def handle_info(
        {:DOWN, reference, :process, connection, reason},
        %{connection: connection, connection_monitor: reference} = state
      ) do
    if reason not in [:normal, :shutdown] and not DisconnectReason.expected_exit?(reason) do
      notify(state, {:error, %Error{message: "connection exited: #{inspect(reason)}"}})
    end

    restart? = state.status == :restarting
    notify(state, {:disconnected, DisconnectReason.from_exit(reason, state.status)})

    state =
      state
      |> cancel_history_pause()
      |> Map.merge(%{connection: nil, connection_monitor: nil, status: :disconnected})

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
    connection_options = Keyword.put(state.options, :store, state.store)

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

  defp fetch_store(options) do
    cond do
      Keyword.has_key?(options, :sessions_path) ->
        {:error, {:unsupported_option, :sessions_path}}

      Keyword.has_key?(options, :store) ->
        {:ok, Keyword.fetch!(options, :store)}

      true ->
        {:error, :store_required}
    end
  end

  defp message_timestamp(%DateTime{} = timestamp), do: timestamp
  defp message_timestamp(timestamp), do: DateTime.from_unix!(timestamp)

  defp public_key(%MessageKey{} = key), do: key
  defp public_key(key) when is_map(key), do: struct!(MessageKey, key)

  defp public_target_key(%Baileys.Proto.MessageKey{} = key, fallback, from_me, participant) do
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
      %Baileys.Proto.Message{reactionMessage: reaction}
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
      %Baileys.Proto.Message{protocolMessage: protocol}
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

  defp normalized_content(%Baileys.Proto.Message{} = content),
    do: normalized_content(content, 0)

  defp normalized_content(content), do: content

  defp normalized_content(%Baileys.Proto.Message{} = content, depth) when depth < 8 do
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
      with {:ok, left} <- Baileys.JID.decode(jid),
           {:ok, right} <- Baileys.JID.decode(own) do
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

  defp enqueue_history(envelopes, state) do
    {queue, added?} =
      Enum.reduce(envelopes, {Map.get(state, :history_queue, :queue.new()), false}, fn envelope,
                                                                                       {queue,
                                                                                        added?} ->
        case HistorySync.detect(envelope.content) do
          {:ok, notification} when envelope.key.from_me ->
            if history_processed?(notification, state) do
              {queue, added?}
            else
              {:queue.in(notification, queue), true}
            end

          _not_history ->
            {queue, added?}
        end
      end)

    if added?, do: start_next_history(Map.put(state, :history_queue, queue)), else: state
  end

  defp start_next_history(state) do
    if Map.get(state, :history_worker) do
      state
    else
      do_start_next_history(state)
    end
  end

  defp do_start_next_history(state) do
    case :queue.out(Map.get(state, :history_queue, :queue.new())) do
      {{:value, notification}, queue} ->
        reference = make_ref()
        client = self()
        downloader = Keyword.get(state.options, :history_downloader, &Download.get/1)

        {worker, monitor} =
          spawn_monitor(fn ->
            downloaded =
              if is_binary(notification.initialHistBootstrapInlinePayload) and
                   byte_size(notification.initialHistBootstrapInlinePayload) > 0 do
                {:ok, nil}
              else
                downloader.(notification.directPath)
              end

            result =
              with {:ok, bytes} <- downloaded do
                HistorySync.process(notification, bytes)
              end

            send(client, {:history_result, reference, result})
          end)

        state
        |> Map.put(:history_queue, queue)
        |> Map.put(:history_worker, {reference, notification, worker, monitor})

      {:empty, _queue} ->
        state
    end
  end

  defp commit_history(%{connection: connection} = _state, mappings, tokens, history, notification)
       when is_pid(connection) do
    ConnectionProcess.commit_history(connection, mappings, tokens, %{
      sync_type: history.sync_type,
      progress: history.progress,
      chunk_order: history.chunk_order,
      request_id: history.request_id,
      peer_data_request_session_id: history.peer_data_request_session_id,
      original_message_id: history.original_message_id,
      pending_notification: Protobuf.encode(notification)
    })
  catch
    :exit, _reason -> {:error, :not_connected}
  end

  defp commit_history(_state, _mappings, _tokens, _history, _notification),
    do: {:error, :not_connected}

  defp history_privacy_tokens(history, mappings, state) do
    persisted = state |> Map.get(:credentials, %{}) |> Map.get(:lid_mappings, %{})
    mapped_lids = Map.merge(persisted, Map.new(mappings, &{&1.pn, &1.lid}))

    Enum.flat_map(history.conversations, fn conversation ->
      web = conversation.web_conversation
      jid = conversation.lid || mapped_lids[conversation.id] || conversation.id

      if is_binary(jid) and is_binary(web.tcToken) and byte_size(web.tcToken) > 0 and
           is_integer(web.tcTokenTimestamp) do
        [%{jid: jid, token: web.tcToken, timestamp: web.tcTokenTimestamp}]
      else
        []
      end
    end)
  end

  defp history_latest?(history, state) do
    progress = state |> Map.get(:credentials, %{}) |> Map.get(:history_sync_progress, %{})
    history.sync_type != :on_demand and map_size(progress) == 0
  end

  defp history_processed?(notification, state) do
    progress = state |> Map.get(:credentials, %{}) |> Map.get(:history_sync_progress, %{})
    key = history_notification_key(notification)

    case progress[key] do
      %{chunk_order: chunk} when is_integer(chunk) and is_integer(notification.chunkOrder) ->
        chunk >= notification.chunkOrder

      _missing ->
        false
    end
  end

  defp history_notification_key(notification) do
    metadata = notification.fullHistorySyncOnDemandRequestMetadata

    (metadata && metadata.requestId) || notification.peerDataRequestSessionId ||
      notification.originalMessageId ||
      history_sync_type_string(notification.syncType)
  end

  defp requeue_history(notification, state) do
    Map.put(state, :history_queue, :queue.in_r(notification, state.history_queue))
  end

  defp retry_history(notification, state) do
    key = history_notification_key(notification)
    retries = Map.get(state, :history_retries, %{})
    count = Map.get(retries, key, 0) + 1
    state = Map.put(state, :history_retries, Map.put(retries, key, count))

    if count <= 3 and Map.get(state, :status) == :online,
      do: requeue_history(notification, state),
      else: state
  end

  defp history_sync_type_string(type) when is_atom(type),
    do: type |> Atom.to_string() |> String.downcase()

  defp history_sync_type_string(type) when is_integer(type), do: "unknown-#{type}"
  defp history_sync_type_string(_type), do: "unknown"

  defp pending_history_queue(credentials) do
    Enum.reduce(credentials.pending_history_sync, :queue.new(), fn encoded, queue ->
      try do
        :queue.in(Baileys.Proto.Message.HistorySyncNotification.decode(encoded), queue)
      rescue
        _error -> queue
      end
    end)
  end

  defp update_history_status(history, state) do
    complete? =
      history.sync_type == :initial_bootstrap or
        (history.sync_type == :recent and history.progress == 100)

    cond do
      complete? ->
        cancel_timer(state.history_pause_timer)
        completed = Map.get(state, :history_completed, MapSet.new())

        if not MapSet.member?(completed, history.sync_type) do
          notify(state, {
            :messaging_history_status,
            %MessagingHistoryStatus{
              sync_type: history.sync_type,
              status: :complete,
              explicit?: true
            }
          })
        end

        state
        |> Map.put(:history_pause_timer, nil)
        |> Map.put(:history_completed, MapSet.put(completed, history.sync_type))

      history.sync_type == :recent ->
        cancel_timer(state.history_pause_timer)
        token = make_ref()
        timer = Process.send_after(self(), {:history_pause, history.sync_type, token}, 120_000)
        %{state | history_pause_timer: {timer, token}}

      true ->
        state
    end
  end

  defp notify(state, event) do
    client = self()

    Enum.each(state.subscribers, fn {subscriber, _monitor} ->
      send(subscriber, {:baileys, client, event})
    end)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer({timer, _token}), do: Process.cancel_timer(timer)
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp cancel_history_pause(state) do
    cancel_timer(Map.get(state, :history_pause_timer))
    Map.put(state, :history_pause_timer, nil)
  end

  defp stop_history_worker(
         %{history_worker: {_reference, _notification, worker, monitor}} = state
       ) do
    Process.exit(worker, :kill)
    Process.demonitor(monitor, [:flush])
    %{state | history_worker: nil}
  end

  defp stop_history_worker(state), do: state

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
