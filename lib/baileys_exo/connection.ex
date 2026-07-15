defmodule BaileysExo.ConnectionProcess do
  @moduledoc false

  use GenServer

  require Logger

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.{Codec, Node, NodeUtils}
  alias BaileysExo.{AppState, Calls, Crypto, Noise}
  alias BaileysExo.HistorySync
  alias BaileysExo.JID
  alias BaileysExo.Protocol.Handshake
  alias BaileysExo.Protocol.{Pairing, USync}
  alias BaileysExo.Proto.Message
  alias BaileysExo.Messages.{GroupNotification, Notification, Receiver, Sender}
  alias BaileysExo.Signal.{SenderKey, SessionCipher}
  alias BaileysExo.Signal.PreKeys
  alias BaileysExo.Store.File, as: FileStore
  alias BaileysExo.Transport.WebSocket

  @default_max_retry_count 5
  @default_max_retry_requesters 16
  @default_incoming_retry_budget 100
  @default_max_persisted_pre_keys PreKeys.initial_count() + @default_incoming_retry_budget
  @default_call_offer_limit 100
  @default_call_offer_ttl 300_000
  @app_state_collections [
    "critical_block",
    "critical_unblock_low",
    "regular_high",
    "regular_low",
    "regular"
  ]
  @default_sent_message_bytes 1_048_576
  @default_sent_message_limit 100

  def start_link(owner, %Credentials{} = credentials, options \\ []) do
    GenServer.start_link(__MODULE__, {owner, credentials, options})
  end

  def close(connection), do: GenServer.call(connection, :close)

  def request_pairing_code(connection, phone, custom_code \\ nil) do
    GenServer.call(connection, {:pairing_code, phone, custom_code}, 30_000)
  end

  def query(connection, node, timeout \\ 30_000) do
    GenServer.call(connection, {:query, node, timeout}, timeout + 1_000)
  end

  def relay(connection, node), do: GenServer.call(connection, {:relay, node}, 30_000)

  def relay(connection, node, retry_material) do
    GenServer.call(connection, {:relay, node, retry_material}, 30_000)
  end

  def commit_credentials(connection, base, credentials) do
    GenServer.call(connection, {:commit_credentials, base, credentials}, 30_000)
  end

  def commit_history(connection, mappings, tokens, progress) do
    GenServer.call(connection, {:commit_history, mappings, tokens, progress}, 30_000)
  end

  @doc false
  def dispatch(%Node{} = node, state), do: handle_node(node, state)

  @impl true
  def format_status(%{state: state} = status) when is_map(state) do
    state =
      state
      |> Map.put(:sent_messages, {:redacted, map_size(Map.get(state, :sent_messages, %{}))})
      |> redact_status_field(:pending_queries)
      |> redact_status_field(:qr_refs)
      |> redact_status_field(:credentials)
      |> redact_status_field(:ephemeral_key)
      |> redact_status_field(:noise)

    status
    |> Map.put(:state, state)
    |> redact_status_field(:log)
    |> redact_status_field(:message)
    |> redact_status_field(:reason)
  end

  def format_status(status), do: status

  def logout(connection, jid) do
    node = %Node{
      tag: "iq",
      attrs: %{
        "to" => "s.whatsapp.net",
        "type" => "set",
        "xmlns" => "md"
      },
      content: [
        %Node{
          tag: "remove-companion-device",
          attrs: %{"jid" => jid, "reason" => "user_initiated"}
        }
      ]
    }

    query(connection, node)
  end

  @impl true
  def init({owner, credentials, options}) do
    Process.flag(:trap_exit, true)
    send(owner, {:connection_event, {:connection, :connecting}})

    case WebSocket.start_link(self(), routing_info: credentials.routing_info) do
      {:ok, transport} ->
        {:ok,
         %{
           owner: owner,
           credentials: credentials,
           options: options,
           transport: transport,
           ephemeral_key: nil,
           noise: nil,
           phase: :waiting_transport,
           pending_queries: %{},
           qr_refs: [],
           qr_count: 0,
           qr_timer: nil,
           keepalive_timer: nil,
           sent_messages: %{},
           sent_message_order: [],
           sent_message_limit:
             Keyword.get(options, :sent_message_limit, @default_sent_message_limit),
           sent_message_bytes: 0,
           sent_message_byte_limit:
             Keyword.get(options, :sent_message_byte_limit, @default_sent_message_bytes),
           retry_counts: %{},
           max_retry_count: Keyword.get(options, :max_retry_count, @default_max_retry_count),
           incoming_retry_counts: %{},
           incoming_retry_order: [],
           incoming_retry_total: 0,
           incoming_retry_limit:
             Keyword.get(options, :incoming_retry_limit, @default_sent_message_limit),
           incoming_retry_budget:
             Keyword.get(options, :incoming_retry_budget, @default_incoming_retry_budget),
           call_offers: %{},
           call_offer_order: [],
           call_offer_limit: Keyword.get(options, :call_offer_limit, @default_call_offer_limit),
           call_offer_ttl: Keyword.get(options, :call_offer_ttl, @default_call_offer_ttl),
           app_state_worker: nil,
           max_retry_requesters:
             Keyword.get(options, :max_retry_requesters, @default_max_retry_requesters),
           session_path: Keyword.get(options, :session_path)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:transport_open, transport}, %{transport: transport} = state) do
    ephemeral_key = Crypto.generate_x25519_key_pair()
    noise = Noise.new(ephemeral_key.public, state.credentials.routing_info)
    client_hello = Handshake.client_hello(ephemeral_key.public)
    {frame, noise} = Noise.encode_frame(noise, client_hello)

    case WebSocket.send_binary(transport, frame) do
      :ok ->
        {:noreply,
         %{state | ephemeral_key: ephemeral_key, noise: noise, phase: :waiting_server_hello}}

      {:error, reason} ->
        stop_with_error(reason, state)
    end
  end

  def handle_info({:transport_binary, data}, state) do
    case Noise.push(state.noise, data) do
      {:ok, frames, noise} ->
        process_frames(frames, %{state | noise: noise})

      {:error, reason} ->
        stop_with_error(reason, state)
    end
  end

  def handle_info({:transport_error, reason}, state), do: stop_with_error(reason, state)
  def handle_info({:transport_closed, reason}, state), do: stop_with_error(reason, state)

  def handle_info(:next_qr, %{qr_refs: []} = state) do
    stop_with_error(:qr_timeout, %{state | qr_timer: nil})
  end

  def handle_info(:next_qr, state) do
    {:noreply, emit_next_qr(%{state | qr_timer: nil})}
  end

  def handle_info(:keepalive, %{phase: :transport} = state) do
    ping = %Node{
      tag: "iq",
      attrs: %{
        "to" => "s.whatsapp.net",
        "type" => "get",
        "xmlns" => "w:p",
        "id" => message_tag()
      },
      content: [%Node{tag: "ping"}]
    }

    case send_node(ping, %{state | keepalive_timer: nil}) do
      {:ok, state} -> {:noreply, schedule_keepalive(state)}
      {:error, reason} -> stop_with_error(reason, state)
    end
  end

  def handle_info({:query_timeout, id}, state) do
    case Map.pop(state.pending_queries, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{:external, from, _timer}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending_queries: pending}}

      {{:prekeys_replenish, _credentials, _last_id, notification, attempt, _timer}, pending} ->
        state = %{state | pending_queries: pending}

        case retry_prekey_replenishment(notification, attempt, state) do
          {:ok, state} -> {:noreply, state}
          {:error, reason} -> stop_with_error(reason, state)
        end

      {{_kind, _credentials, _metadata, _timer}, pending} ->
        stop_with_error({:query_timeout, id}, %{state | pending_queries: pending})

      {{_kind, _credentials, _timer}, pending} ->
        stop_with_error({:query_timeout, id}, %{state | pending_queries: pending})
    end
  end

  def handle_info({:EXIT, transport, reason}, %{transport: transport} = state) do
    stop_with_error(reason, state)
  end

  def handle_info(
        {:app_state_result, reference, result},
        %{app_state_worker: {reference, base_pending}} = state
      ) do
    state = %{state | app_state_worker: nil}

    case result do
      {:ok, credentials, mutations} ->
        credentials = merge_app_state_credentials(state.credentials, credentials, base_pending)

        with :ok <- persist_credentials(state.session_path, credentials) do
          send(state.owner, {:connection_event, {:credentials, credentials}})
          send(state.owner, {:connection_event, {:app_state_mutations, mutations}})

          send(
            state.owner,
            {:connection_event, {:app_state_effects, AppState.project_effects(mutations)}}
          )

          case maybe_start_app_state_sync(%{state | credentials: credentials}) do
            {:ok, state} -> {:noreply, state}
            {:error, reason} -> stop_with_error(reason, state)
          end
        else
          {:error, reason} -> stop_with_error(reason, state)
        end

      {:error, reason} ->
        send(state.owner, {:connection_event, {:error, {:app_state_sync_failed, reason}}})
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:close, _from, state) do
    cancel_timer(state.qr_timer)
    cancel_timer(state.keepalive_timer)
    WebSocket.close(state.transport)
    {:stop, :normal, :ok, state}
  end

  def handle_call({:pairing_code, phone, custom_code}, _from, %{phase: :transport} = state) do
    with {:ok, code, node, credentials} <-
           Pairing.request_code(state.credentials, phone, custom_code),
         :ok <- persist_credentials(state.session_path, credentials),
         {:ok, state} <- send_node(node, %{state | credentials: credentials}) do
      send(state.owner, {:connection_event, {:credentials, credentials}})
      {:reply, {:ok, code}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:pairing_code, _phone, _custom_code}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:query, node, timeout}, from, %{phase: :transport} = state) do
    id = node.attrs["id"] || message_tag()
    node = %{node | attrs: Map.put(node.attrs, "id", id)}

    case send_node(node, state) do
      {:ok, state} ->
        timer = Process.send_after(self(), {:query_timeout, id}, timeout)
        pending = Map.put(state.pending_queries, id, {:external, from, timer})
        {:noreply, %{state | pending_queries: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:query, _node, _timeout}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:relay, node}, _from, %{phase: :transport} = state) do
    case send_node(node, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:relay, node, retry_material}, _from, %{phase: :transport} = state) do
    case send_node(node, state) do
      {:ok, state} -> {:reply, :ok, remember_sent_message(state, node, retry_material)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:relay, _node}, _from, state), do: {:reply, {:error, :not_connected}, state}

  def handle_call({:relay, _node, _retry_material}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:commit_credentials, base, credentials}, _from, state) do
    with {:ok, credentials} <- merge_sender_credentials(state.credentials, base, credentials),
         :ok <- persist_credentials(state.session_path, credentials) do
      send(state.owner, {:connection_event, {:credentials, credentials}})
      {:reply, {:ok, credentials}, %{state | credentials: credentials}}
    else
      {:error, :credentials_conflict} = error -> {:reply, error, state}
      {:error, reason} -> {:reply, {:error, {:store, reason}}, state}
    end
  end

  def handle_call({:commit_history, mappings, tokens, progress}, _from, state) do
    credentials =
      Enum.reduce(mappings, state.credentials, fn %{pn: pn, lid: lid}, credentials ->
        put_in(credentials.lid_mappings[pn], lid)
      end)

    credentials =
      Enum.reduce(tokens, credentials, fn %{jid: jid, token: token, timestamp: timestamp},
                                          credentials ->
        current = credentials.privacy_tokens[jid]

        if is_nil(current) or timestamp >= current.timestamp do
          put_in(credentials.privacy_tokens[jid], %{token: token, timestamp: timestamp})
        else
          credentials
        end
      end)

    key =
      progress.request_id || progress.peer_data_request_session_id || progress.original_message_id ||
        sync_type_string(progress.sync_type)

    pending_notification = progress[:pending_notification]
    progress = Map.delete(progress, :pending_notification)
    credentials = put_in(credentials.history_sync_progress[key], progress)

    pending_history_sync =
      List.delete(credentials.pending_history_sync, pending_notification)

    credentials = %{credentials | pending_history_sync: pending_history_sync}

    case persist_credentials(state.session_path, credentials) do
      :ok ->
        send(state.owner, {:connection_event, {:credentials, credentials}})
        {:reply, :ok, %{state | credentials: credentials}}

      {:error, reason} ->
        {:reply, {:error, {:store, reason}}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.qr_timer)
    cancel_timer(state.keepalive_timer)
    close_transport(state.transport)
    :ok
  end

  defp process_frames([], state), do: {:noreply, state}

  defp process_frames([frame | frames], %{phase: :waiting_server_hello} = state) do
    case Handshake.process_server_hello(
           frame,
           state.noise,
           state.ephemeral_key,
           state.credentials,
           state.options
         ) do
      {:ok, client_finish_frame, noise} ->
        case WebSocket.send_binary(state.transport, client_finish_frame) do
          :ok -> process_frames(frames, %{state | noise: noise, phase: :transport})
          {:error, reason} -> stop_with_error(reason, state)
        end

      {:error, reason} ->
        stop_with_error(reason, state)
    end
  end

  defp process_frames([frame | frames], %{phase: :transport} = state) do
    case Codec.decode(frame) do
      {:ok, node} ->
        case handle_node(node, state) do
          {:ok, state} -> process_frames(frames, state)
          {:error, reason} -> stop_with_error(reason, state)
        end

      {:error, reason} ->
        stop_with_error(reason, state)
    end
  end

  defp handle_node(%Node{tag: "iq", attrs: %{"type" => "set"}} = node, state) do
    cond do
      NodeUtils.child(node, "pair-success") ->
        with {:ok, reply, credentials} <- Pairing.pair_success(node, state.credentials),
             :ok <- persist_credentials(state.session_path, credentials),
             {:ok, state} <- send_node(reply, %{state | credentials: credentials}) do
          send(state.owner, {:connection_event, {:credentials, credentials}})
          send(state.owner, {:connection_event, {:paired, credentials.me}})
          {:ok, state}
        end

      pair_device = NodeUtils.child(node, "pair-device") ->
        ack = %Node{
          tag: "iq",
          attrs: %{"to" => "s.whatsapp.net", "type" => "result", "id" => node.attrs["id"]}
        }

        with {:ok, state} <- send_node(ack, state) do
          refs =
            pair_device
            |> NodeUtils.children("ref")
            |> Enum.map(& &1.content)
            |> Enum.filter(&is_binary/1)

          {:ok, emit_next_qr(%{state | qr_refs: refs, qr_count: 0})}
        end

      true ->
        {:ok, state}
    end
  end

  defp handle_node(%Node{tag: "iq", attrs: %{"id" => id, "type" => type}} = node, state)
       when type in ["result", "error"] do
    case Map.pop(state.pending_queries, id) do
      {nil, _pending} ->
        {:ok, state}

      {{:external, from, timer}, pending} ->
        Process.cancel_timer(timer)
        reply = if type == "result", do: {:ok, node}, else: {:error, node}
        GenServer.reply(from, reply)
        {:ok, %{state | pending_queries: pending}}

      {{:prekeys, credentials, last_id, timer}, pending} ->
        Process.cancel_timer(timer)

        if type == "result" do
          credentials = %{credentials | first_unuploaded_pre_key_id: last_id + 1}

          with :ok <- persist_credentials(state.session_path, credentials) do
            send(state.owner, {:connection_event, {:credentials, credentials}})
            go_online(%{state | credentials: credentials, pending_queries: pending})
          end
        else
          {:error, {:prekey_upload_failed, node}}
        end

      {{:prekeys_replenish, credentials, last_id, notification, attempt, timer}, pending} ->
        Process.cancel_timer(timer)

        if type == "result" do
          credentials = %{
            state.credentials
            | first_unuploaded_pre_key_id: last_id + 1,
              next_pre_key_id: max(state.credentials.next_pre_key_id, credentials.next_pre_key_id)
          }

          with :ok <- persist_credentials(state.session_path, credentials) do
            send(state.owner, {:connection_event, {:credentials, credentials}})

            send_node(Receiver.ack(notification, credentials), %{
              state
              | credentials: credentials,
                pending_queries: pending
            })
          end
        else
          retry_prekey_replenishment(notification, attempt, %{state | pending_queries: pending})
        end

      {{:app_state_sync, _collections, timer}, pending} ->
        Process.cancel_timer(timer)

        if type == "result" do
          reference = make_ref()
          connection = self()
          credentials = state.credentials

          Task.start(fn ->
            send(
              connection,
              {:app_state_result, reference, AppState.process_response(node, credentials)}
            )
          end)

          {:ok,
           %{
             state
             | pending_queries: pending,
               app_state_worker: {reference, credentials.pending_app_state_sync}
           }}
        else
          {:ok, %{state | pending_queries: pending}}
        end

      {{:pairing_finish, credentials, timer}, pending} ->
        Process.cancel_timer(timer)

        if type == "result" do
          credentials = %{credentials | registered?: true}

          with :ok <- persist_credentials(state.session_path, credentials) do
            send(state.owner, {:connection_event, {:credentials, credentials}})
            {:ok, %{state | credentials: credentials, pending_queries: pending}}
          end
        else
          {:error, {:pairing_code_failed, node}}
        end
    end
  end

  defp handle_node(%Node{tag: "notification"} = node, state) do
    process_and_ack(node, state, fn -> process_notification(node, state) end)
  end

  defp handle_node(%Node{tag: "message"} = node, state) do
    if NodeUtils.child(node, "enc") do
      case decrypt_message(node, state.credentials) do
        {:ok, envelope, credentials, protocol_response} ->
          state = clear_incoming_retry(node, state)

          with {:ok, state} <- acknowledge_message(credentials, protocol_response, state),
               {:ok, state} <- acknowledge_history(envelope, state),
               {:ok, state} <- schedule_initial_app_state(envelope, state),
               {:ok, state} <- maybe_start_app_state_sync(state) do
            upsert_type = if envelope.offline, do: :append, else: :notify

            send(state.owner, {
              :connection_event,
              {:messages_upsert, [envelope], upsert_type, nil}
            })

            projection =
              (envelope.content.deviceSentMessage && envelope.content.deviceSentMessage.message) ||
                envelope.content

            case Receiver.extract_text(projection) do
              {:ok, text} ->
                metadata = Receiver.text_metadata(envelope)
                send(state.owner, {:connection_event, {:text_message, metadata, text}})

              :unsupported ->
                :ok
            end

            {:ok, state}
          end

        {:error, reason, credentials} ->
          handle_message_decrypt_failure(node, reason, credentials, state)

        {:error, reason} ->
          handle_message_decrypt_failure(node, reason, state.credentials, state)
      end
    else
      send_node(Receiver.ack(node, state.credentials), state)
    end
  end

  defp handle_node(%Node{tag: "ack", attrs: %{"class" => "message", "id" => id}} = node, state) do
    if node.attrs["error"] do
      timestamp = Receiver.receipt_timestamp(node, receipt_clock(state))
      recipient = failed_ack_recipient(node, id, state)

      send(state.owner, {
        :connection_event,
        {:message_status, id, recipient, :failed, timestamp, node.attrs}
      })

      send(state.owner, {
        :connection_event,
        {:messages_update,
         [
           %{
             key: failed_ack_key(node, id, state),
             update: %{status: :failed, timestamp: timestamp, error: node.attrs}
           }
         ]}
      })
    end

    {:ok, state}
  end

  defp handle_node(%Node{tag: "receipt"} = node, state), do: handle_receipt(node, state)

  defp handle_node(%Node{tag: "call"} = node, state) do
    process_and_ack(node, state, fn -> process_call(node, state) end)
  end

  defp handle_node(%Node{tag: "ib"} = node, state) do
    case Receiver.offline_batch_request(node) do
      {:ok, request} ->
        send_node(request, state)

      :ignore ->
        handle_ib_node(node, state)
    end
  end

  defp handle_node(%Node{tag: "success"}, state) do
    active = %Node{
      tag: "iq",
      attrs: %{
        "to" => "s.whatsapp.net",
        "xmlns" => "passive",
        "type" => "set",
        "id" => message_tag()
      },
      content: [%Node{tag: "active"}]
    }

    with {:ok, state} <- send_node(active, state) do
      finish_login(state)
    end
  end

  defp handle_node(%Node{tag: tag}, _state) when tag in ["stream:error", "xmlstreamend"] do
    {:error, :restart_required}
  end

  defp handle_node(_node, state), do: {:ok, state}

  defp process_notification(node, state) do
    cond do
      node.attrs["type"] == "w:gp2" ->
        case GroupNotification.decode(node, state.credentials) do
          {:ok, envelope, effect} ->
            send(state.owner, {
              :connection_event,
              {:messages_upsert, [envelope], :append, nil}
            })

            send(state.owner, {:connection_event, {:group_effect, effect}})
            {:ok, state}

          {:error, _reason} ->
            {:ok, state}
        end

      node.attrs["type"] in ["picture", "account_sync", "mediaretry", "privacy_token"] ->
        process_external_notification(node, state)

      node.attrs["type"] == "devices" ->
        process_devices_notification(node, state)

      node.attrs["type"] == "encrypt" ->
        process_encrypt_notification(node, state)

      node.attrs["type"] == "server_sync" ->
        process_server_sync_notification(node, state)

      NodeUtils.child(node, "link_code_companion_reg") ->
        with {:ok, reply, credentials} <- Pairing.finish_code(node, state.credentials),
             :ok <- persist_credentials(state.session_path, credentials),
             {:ok, state} <-
               track_internal_query(reply, {:pairing_finish, credentials}, %{
                 state
                 | credentials: credentials
               }) do
          send(state.owner, {:connection_event, {:credentials, credentials}})
          {:ok, state}
        end

      true ->
        {:ok, state}
    end
  end

  defp process_external_notification(node, state) do
    case Notification.decode(node, state.credentials) do
      {:ok, effects, credentials} ->
        with {:ok, state} <- maybe_commit_credentials(credentials, state) do
          Enum.each(effects, &emit_notification_effect(&1, state.owner))
          {:ok, state}
        end

      {:error, _reason} ->
        {:ok, state}
    end
  end

  defp emit_notification_effect({:messages_upsert, messages, type, request_id}, owner) do
    send(owner, {:connection_event, {:messages_upsert, messages, type, request_id}})
  end

  defp emit_notification_effect({:media_update, updates}, owner) do
    send(owner, {:connection_event, {:messages_media_update, updates}})
  end

  defp emit_notification_effect({type, payload}, owner) do
    send(owner, {:connection_event, {type, payload}})
  end

  defp process_devices_notification(node, state) do
    case first_node_child(node) do
      %Node{tag: "remove"} = operation ->
        device_jids =
          operation
          |> NodeUtils.children("device")
          |> Enum.map(& &1.attrs["jid"])
          |> Enum.filter(&(is_binary(&1) and &1 != ""))

        update_credentials(state, fn credentials ->
          addresses = Enum.flat_map(device_jids, &session_aliases(credentials, &1))
          %{credentials | sessions: Map.drop(credentials.sessions, addresses)}
        end)

      %Node{tag: tag} when tag in ["add", "update"] ->
        {:ok, state}

      _unsupported ->
        {:ok, state}
    end
  end

  defp process_encrypt_notification(%Node{attrs: %{"from" => "s.whatsapp.net"}} = node, state) do
    count =
      case NodeUtils.child(node, "count") do
        %Node{attrs: %{"value" => value}} -> parse_non_negative_integer(value)
        _missing -> nil
      end

    cond do
      not is_integer(count) or count >= 5 ->
        {:ok, state}

      prekey_replenishment_pending?(state) ->
        {:ok, state}

      true ->
        case start_prekey_replenishment(node, 1, state) do
          {:ok, state} -> {:defer_ack, state}
          {:error, _reason} = error -> error
        end
    end
  end

  defp process_encrypt_notification(node, state) do
    if not is_nil(NodeUtils.child(node, "identity")) and
         peer_identity_change?(node, state.credentials) do
      update_credentials(state, fn credentials ->
        sessions =
          Map.reject(credentials.sessions, fn {address, _record} ->
            same_jid_account?(address, node.attrs["from"], credentials)
          end)

        %{credentials | sessions: sessions}
      end)
    else
      {:ok, state}
    end
  end

  defp process_server_sync_notification(node, state) do
    case NodeUtils.child(node, "collection") do
      %Node{attrs: %{"name" => name}} when name in @app_state_collections ->
        with {:ok, state} <-
               update_credentials(state, fn credentials ->
                 pending =
                   if app_state_sync_inflight?(state),
                     do: credentials.pending_app_state_sync ++ [name],
                     else: List.delete(credentials.pending_app_state_sync, name) ++ [name]

                 %{credentials | pending_app_state_sync: pending}
               end),
             {:ok, state} <- maybe_start_app_state_sync(state) do
          {:ok, state}
        end

      _missing ->
        {:ok, state}
    end
  end

  defp update_credentials(state, update) do
    credentials = update.(state.credentials)

    maybe_commit_credentials(credentials, state)
  end

  defp maybe_commit_credentials(credentials, state) do
    if credentials == state.credentials do
      {:ok, state}
    else
      with :ok <- persist_credentials(Map.get(state, :session_path), credentials) do
        send(state.owner, {:connection_event, {:credentials, credentials}})
        {:ok, %{state | credentials: credentials}}
      end
    end
  end

  defp merge_sender_credentials(current, base, updated) do
    allowed_fields = [:sessions, :lid_mappings]

    base_static = base |> Map.from_struct() |> Map.drop(allowed_fields)
    updated_static = updated |> Map.from_struct() |> Map.drop(allowed_fields)

    if base_static == updated_static do
      with {:ok, sessions} <-
             merge_credential_map(current.sessions, base.sessions, updated.sessions),
           {:ok, lid_mappings} <-
             merge_credential_map(current.lid_mappings, base.lid_mappings, updated.lid_mappings) do
        {:ok, %{current | sessions: sessions, lid_mappings: lid_mappings}}
      end
    else
      {:error, :credentials_conflict}
    end
  end

  defp merge_app_state_credentials(current, updated, base_pending) do
    concurrently_added = list_difference(current.pending_app_state_sync, base_pending)
    pending = updated.pending_app_state_sync ++ concurrently_added

    %{
      current
      | app_state_sync_keys: Map.merge(current.app_state_sync_keys, updated.app_state_sync_keys),
        app_state_collections: updated.app_state_collections,
        pending_app_state_sync: pending,
        my_app_state_key_id: updated.my_app_state_key_id || current.my_app_state_key_id,
        lid_mappings: Map.merge(current.lid_mappings, updated.lid_mappings)
    }
  end

  defp list_difference(values, remove) do
    Enum.reduce(remove, values, fn value, remaining -> List.delete(remaining, value) end)
  end

  defp merge_credential_map(current, base, updated) do
    changed_keys =
      base
      |> Map.keys()
      |> Kernel.++(Map.keys(updated))
      |> Enum.uniq()
      |> Enum.filter(&(Map.get(base, &1) != Map.get(updated, &1)))

    Enum.reduce_while(changed_keys, {:ok, current}, fn key, {:ok, merged} ->
      base_value = Map.get(base, key)

      if Map.get(current, key) == base_value do
        merged =
          if Map.has_key?(updated, key),
            do: Map.put(merged, key, Map.fetch!(updated, key)),
            else: Map.delete(merged, key)

        {:cont, {:ok, merged}}
      else
        {:halt, {:error, :credentials_conflict}}
      end
    end)
  end

  defp first_node_child(%Node{content: content}) when is_list(content),
    do: Enum.find(content, &match?(%Node{}, &1))

  defp first_node_child(_node), do: nil

  defp prekey_replenishment_pending?(state) do
    state
    |> Map.get(:pending_queries, %{})
    |> Map.values()
    |> Enum.any?(
      &match?(
        {:prekeys_replenish, _credentials, _last_id, _notification, _attempt, _timer},
        &1
      )
    )
  end

  defp start_prekey_replenishment(notification, attempt, state) do
    {credentials, upload, last_id} = PreKeys.upload_node(state.credentials, 5)

    with :ok <- persist_credentials(state.session_path, credentials),
         {:ok, state} <-
           track_internal_query(
             upload,
             {:prekeys_replenish, credentials, last_id, notification, attempt},
             %{state | credentials: credentials}
           ) do
      send(state.owner, {:connection_event, {:credentials, credentials}})
      {:ok, state}
    end
  end

  defp retry_prekey_replenishment(notification, attempt, state) when attempt < 3 do
    start_prekey_replenishment(notification, attempt + 1, state)
  end

  defp retry_prekey_replenishment(notification, _attempt, state) do
    send(state.owner, {:connection_event, {:error, :prekey_replenishment_failed}})
    send_node(Receiver.ack(notification, state.credentials), state)
  end

  defp same_jid_user?(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, left} <- JID.decode(left),
         {:ok, right} <- JID.decode(right) do
      left.user == right.user and left.server == right.server
    else
      _invalid -> false
    end
  end

  defp same_jid_user?(_left, _right), do: false

  defp same_jid_account?(address, jid, credentials) do
    credentials
    |> session_aliases(jid)
    |> Enum.any?(&same_jid_user?(address, &1))
  end

  defp session_aliases(credentials, jid) do
    case JID.decode(jid) do
      {:ok, decoded} ->
        bare = JID.encode(decoded.user, decoded.server)

        mapped =
          case credentials.lid_mappings[bare] do
            nil -> []
            mapped -> [with_device(mapped, decoded.device)]
          end

        reverse =
          credentials.lid_mappings
          |> Enum.filter(fn {_pn, lid} -> same_jid_user?(lid, bare) end)
          |> Enum.map(fn {pn, _lid} -> with_device(pn, decoded.device) end)

        Enum.uniq([jid | mapped ++ reverse])

      {:error, :invalid_jid} ->
        [jid]
    end
  end

  defp with_device(jid, device) do
    case JID.decode(jid) do
      {:ok, decoded} -> JID.encode(decoded.user, decoded.server, device)
      {:error, :invalid_jid} -> jid
    end
  end

  defp peer_identity_change?(node, credentials) do
    from = node.attrs["from"]
    me = credentials.me || %{}

    with false <- Map.has_key?(node.attrs, "offline"),
         {:ok, decoded} <- JID.decode(from),
         true <- decoded.device in [nil, 0],
         false <- same_jid_user?(from, me[:id]),
         false <- same_jid_user?(from, me[:lid]) do
      true
    else
      _ignored -> false
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value || "") do
      {integer, ""} when integer >= 0 -> integer
      _invalid -> nil
    end
  end

  defp sync_type_string(type) when is_atom(type), do: Atom.to_string(type)
  defp sync_type_string(type) when is_integer(type), do: "unknown-#{type}"
  defp sync_type_string(_type), do: "unknown"

  defp start_app_state_sync(collections, state) do
    track_internal_query(
      AppState.request_node(collections, state.credentials),
      {:app_state_sync, collections},
      state
    )
  end

  defp maybe_start_app_state_sync(state) do
    pending? =
      state
      |> Map.get(:pending_queries, %{})
      |> Map.values()
      |> Enum.any?(&match?({:app_state_sync, _collections, _timer}, &1))

    cond do
      Map.get(state, :app_state_worker) -> {:ok, state}
      pending? -> {:ok, state}
      state.credentials.pending_app_state_sync == [] -> {:ok, state}
      true -> start_app_state_sync(state.credentials.pending_app_state_sync, state)
    end
  end

  defp app_state_sync_inflight?(state) do
    not is_nil(Map.get(state, :app_state_worker)) or
      Enum.any?(Map.values(Map.get(state, :pending_queries, %{})), fn
        {:app_state_sync, _collections, _timer} -> true
        _other -> false
      end)
  end

  defp process_call(node, state) do
    case Calls.decode(node, receipt_clock(state)) do
      {:ok, call} ->
        {call, state} = enrich_call_from_offer(call, state)
        send(state.owner, {:connection_event, {:call, [call]}})
        {:ok, state}

      {:error, _reason} ->
        {:ok, state}
    end
  end

  defp enrich_call_from_offer(call, state) do
    now = call_cache_clock(state).()
    {offers, order} = prune_call_offers(state, now)
    cached = offers[call.id]

    call =
      if cached do
        call
        |> Map.put(:from, call.from || cached.from)
        |> Map.put(:caller_pn, call.caller_pn || cached.caller_pn)
        |> Map.put(:is_video?, cached.is_video?)
        |> Map.put(:is_group?, cached.is_group?)
        |> Map.put(:group_jid, call.group_jid || cached.group_jid)
      else
        call
      end

    {offers, order} =
      cond do
        Calls.offer?(call) ->
          order = List.delete(order, call.id) ++ [call.id]
          offers = Map.put(offers, call.id, Map.put(call, :expires_at, call_expiry(state, now)))
          trim_call_offers(offers, order, state)

        Calls.terminal?(call) ->
          {Map.delete(offers, call.id), List.delete(order, call.id)}

        true ->
          {offers, order}
      end

    state =
      state
      |> Map.put(:call_offers, offers)
      |> Map.put(:call_offer_order, order)

    {call, state}
  end

  defp prune_call_offers(state, now) do
    offers = Map.get(state, :call_offers, %{})

    order =
      state
      |> Map.get(:call_offer_order, [])
      |> Enum.filter(fn id ->
        case offers[id] do
          %{expires_at: expires_at} -> expires_at > now
          _missing -> false
        end
      end)

    {Map.take(offers, order), order}
  end

  defp trim_call_offers(offers, order, state) do
    limit = Map.get(state, :call_offer_limit, @default_call_offer_limit)
    {expired, order} = Enum.split(order, max(length(order) - limit, 0))
    {Map.drop(offers, expired), order}
  end

  defp call_expiry(state, now),
    do: now + Map.get(state, :call_offer_ttl, @default_call_offer_ttl)

  defp call_cache_clock(state),
    do: Map.get(state, :monotonic_now, fn -> System.monotonic_time(:millisecond) end)

  defp handle_ib_node(node, state) do
    case NodeUtils.child(node, "edge_routing") do
      %Node{} = edge ->
        case NodeUtils.child(edge, "routing_info") do
          %Node{content: routing_info} when is_binary(routing_info) ->
            credentials = %{state.credentials | routing_info: routing_info}

            with :ok <- persist_credentials(state.session_path, credentials) do
              send(state.owner, {:connection_event, {:credentials, credentials}})
              {:ok, %{state | credentials: credentials}}
            end

          _missing ->
            {:ok, state}
        end

      nil ->
        {:ok, state}
    end
  end

  defp finish_login(state) do
    first = state.credentials.first_unuploaded_pre_key_id
    next = state.credentials.next_pre_key_id

    count =
      cond do
        first == 1 -> PreKeys.initial_count()
        first < next -> next - first
        true -> 0
      end

    if count > 0 do
      {credentials, node, last_id} = PreKeys.upload_node(state.credentials, count)

      with :ok <- persist_credentials(state.session_path, credentials),
           {:ok, state} <-
             track_internal_query(node, {:prekeys, credentials, last_id}, %{
               state
               | credentials: credentials
             }) do
        send(state.owner, {:connection_event, {:credentials, credentials}})
        {:ok, state}
      end
    else
      go_online(state)
    end
  end

  defp go_online(state) do
    send(state.owner, {:connection_event, {:connection, :online}})
    state = schedule_keepalive(state)

    case state.credentials.pending_app_state_sync do
      [] -> {:ok, state}
      collections -> start_app_state_sync(collections, state)
    end
  end

  defp send_node(node, %{node_sender: node_sender} = state) when is_function(node_sender, 1) do
    case node_sender.(node) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_node(node, state) do
    encoded = Codec.encode(node)
    {frame, noise} = Noise.encode_frame(state.noise, encoded)

    case WebSocket.send_binary(state.transport, frame) do
      :ok -> {:ok, %{state | noise: noise}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp track_internal_query(node, kind, state) do
    id = node.attrs["id"] || message_tag()
    node = %{node | attrs: Map.put(node.attrs, "id", id)}

    with {:ok, state} <- send_node(node, state) do
      timer = Process.send_after(self(), {:query_timeout, id}, 30_000)

      pending_entry =
        case kind do
          {:prekeys, credentials, last_id} ->
            {:prekeys, credentials, last_id, timer}

          {:prekeys_replenish, credentials, last_id, notification, attempt} ->
            {:prekeys_replenish, credentials, last_id, notification, attempt, timer}

          {:pairing_finish, credentials} ->
            {:pairing_finish, credentials, timer}

          {:app_state_sync, collections} ->
            {:app_state_sync, collections, timer}
        end

      {:ok,
       Map.put(
         state,
         :pending_queries,
         Map.put(Map.get(state, :pending_queries, %{}), id, pending_entry)
       )}
    end
  end

  defp emit_next_qr(%{qr_refs: []} = state), do: state

  defp emit_next_qr(%{qr_refs: [reference | refs]} = state) do
    payload = Pairing.qr_payload(reference, state.credentials)

    send(state.owner, {:connection_event, {:qr, payload}})
    timeout = if state.qr_count == 0, do: 60_000, else: 20_000
    timer = Process.send_after(self(), :next_qr, timeout)
    %{state | qr_refs: refs, qr_timer: timer, qr_count: state.qr_count + 1}
  end

  defp stop_with_error(:restart_required, state) do
    {:stop, :normal, state}
  end

  defp stop_with_error(reason, state) do
    send(state.owner, {:connection_event, {:error, reason}})
    {:stop, reason, state}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp message_tag do
    "#{System.system_time(:second)}.#{System.unique_integer([:positive])}"
  end

  defp decrypt_message(node, credentials) do
    with {:ok, context} <- Receiver.context(node, credentials),
         credentials = prepare_signal_address(context, credentials),
         encrypted when encrypted != [] <- ordered_encrypted_payloads(node),
         {:ok, message, raw_payloads, credentials} <-
           decrypt_payloads(encrypted, context, credentials) do
      envelope =
        context
        |> Receiver.envelope(message, List.last(raw_payloads))
        |> Map.put(:raw_payloads, raw_payloads)

      {:ok, envelope, credentials, context.protocol_response}
    else
      [] -> {:error, :missing_encrypted_message}
      {:error, _reason} = error -> error
      {:error, _reason, _credentials} = error -> error
      _invalid -> {:error, :unsupported_message}
    end
  rescue
    error -> {:error, error}
  end

  defp prepare_signal_address(context, credentials) do
    with {pn_source, lid_source} <- signal_address_pair(context),
         {:ok, pn} <- JID.decode(pn_source),
         {:ok, lid} <- JID.decode(lid_source),
         true <- pn_lid_pair?(pn.server, lid.server) do
      pn_jid = JID.encode(pn.user, pn.server)
      lid_jid = JID.encode(lid.user, lid.server)
      pn_address = pn_source |> with_device(lid.device || pn.device) |> normalize_signal_address()
      lid_address = normalize_signal_address(context.signal_jid)

      sessions =
        case {credentials.sessions[pn_address], credentials.sessions[lid_address]} do
          {%{} = session, nil} -> Map.put(credentials.sessions, lid_address, session)
          _existing -> credentials.sessions
        end

      %{
        credentials
        | lid_mappings: Map.put(credentials.lid_mappings, pn_jid, lid_jid),
          sessions: sessions
      }
    else
      _not_pn_to_lid -> credentials
    end
  end

  defp signal_address_pair(%{key: %{addressing_mode: :pn}} = context),
    do: {context.wire_sender_jid, context.signal_jid}

  defp signal_address_pair(%{key: %{addressing_mode: :lid} = key} = context),
    do: {key.participant_alt || key.remote_jid_alt, context.signal_jid}

  defp signal_address_pair(_context), do: nil

  defp pn_lid_pair?("s.whatsapp.net", "lid"), do: true
  defp pn_lid_pair?("hosted", "hosted.lid"), do: true
  defp pn_lid_pair?(_pn_server, _lid_server), do: false

  defp ordered_encrypted_payloads(node) do
    node
    |> NodeUtils.children("enc")
    |> Enum.sort_by(&if(&1.attrs["type"] == "skmsg", do: 1, else: 0))
  end

  defp decrypt_payloads(encrypted, context, credentials) do
    encrypted
    |> Enum.reduce(
      {nil, [], credentials, []},
      fn encrypted, {message, raw_payloads, credentials, errors} ->
        case decrypt_encrypted_payload(encrypted, context, credentials) do
          {:ok, decoded, unpadded, credentials} ->
            {merge_messages(message, decoded), [unpadded | raw_payloads], credentials, errors}

          {:error, reason} ->
            {message, raw_payloads, credentials, [{encrypted.attrs["type"], reason} | errors]}
        end
      end
    )
    |> case do
      {message, raw_payloads, credentials, errors} ->
        finish_decrypted_payloads(message, Enum.reverse(raw_payloads), credentials, errors)
    end
  end

  defp finish_decrypted_payloads(message, raw_payloads, credentials, errors) do
    case Enum.find(errors, fn {type, _reason} -> type == "skmsg" end) do
      {_type, reason} ->
        {:error, reason, credentials}

      nil when is_struct(message, Message) and raw_payloads != [] ->
        {:ok, message, raw_payloads, credentials}

      nil when errors != [] ->
        {_type, reason} = hd(errors)
        {:error, reason, credentials}

      nil ->
        {:error, :invalid_encrypted_message, credentials}
    end
  end

  defp decrypt_encrypted_payload(%Node{content: ciphertext, attrs: attrs}, context, credentials)
       when is_binary(ciphertext) do
    with {:ok, plaintext, credentials} <-
           decrypt_payload(attrs["type"], context, ciphertext, credentials),
         {:ok, unpadded} <- unpad_message(plaintext),
         message <- Message.decode(unpadded),
         {:ok, credentials} <- process_sender_key_distribution(message, context, credentials),
         {:ok, credentials} <- AppState.process_key_share(message, credentials, context.from_me) do
      {:ok, message, unpadded, credentials}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :unsupported_message}
    end
  rescue
    error -> {:error, error}
  end

  defp decrypt_encrypted_payload(_encrypted, _context, _credentials),
    do: {:error, :invalid_encrypted_message}

  defp merge_messages(nil, %Message{} = message), do: message

  defp merge_messages(%Message{} = current, %Message{} = incoming) do
    incoming
    |> Map.from_struct()
    |> Enum.reduce(current, fn
      {_field, nil}, message -> message
      {_field, []}, message -> message
      {field, value}, message -> Map.put(message, field, value)
    end)
  end

  defp decrypt_payload("skmsg", context, ciphertext, credentials) do
    key = SenderKey.record_key(context.wire_chat_jid, context.wire_sender_jid)

    with {:ok, record} <- Map.fetch(credentials.sender_keys, key),
         {:ok, plaintext, record} <- SenderKey.decrypt(record, ciphertext) do
      {:ok, plaintext, put_in(credentials.sender_keys[key], record)}
    else
      :error -> {:error, :missing_sender_key}
      {:error, _reason} = error -> error
    end
  end

  defp decrypt_payload(type, context, ciphertext, credentials) do
    address = normalize_signal_address(context.signal_jid)
    record = credentials.sessions[address]

    with {:ok, plaintext, record, used_pre_key} <-
           decrypt_signal(type, record, ciphertext, credentials) do
      credentials = put_in(credentials.sessions[address], record)

      credentials =
        if used_pre_key,
          do: %{credentials | pre_keys: Map.delete(credentials.pre_keys, used_pre_key)},
          else: credentials

      {:ok, plaintext, credentials}
    end
  end

  defp process_sender_key_distribution(message, context, credentials) do
    message = (message.deviceSentMessage && message.deviceSentMessage.message) || message

    case message.senderKeyDistributionMessage do
      %Message.SenderKeyDistributionMessage{
        groupId: group_id,
        axolotlSenderKeyDistributionMessage: distribution
      }
      when is_binary(group_id) and group_id != "" and is_binary(distribution) ->
        key = SenderKey.record_key(group_id, context.wire_sender_jid)

        case SenderKey.process_distribution(credentials.sender_keys[key], distribution) do
          {:ok, record} -> {:ok, put_in(credentials.sender_keys[key], record)}
          {:error, _reason} = error -> error
        end

      _missing ->
        {:ok, credentials}
    end
  end

  defp handle_message_decrypt_failure(node, reason, credentials, state) do
    key = {node.attrs["id"], node.attrs["participant"] || node.attrs["from"]}
    {count, retry?, state} = track_incoming_retry(key, state)
    {retry, credentials} = incoming_retry_receipt(node, count, retry?, credentials)
    state = %{state | credentials: credentials}

    send(state.owner, {
      :connection_event,
      {:error, {:message_decrypt_failed, %{reason: reason, attempt: count, retry?: retry?}}}
    })

    with :ok <- persist_credentials(Map.get(state, :session_path), credentials),
         {:ok, state} <- maybe_send_retry(retry, state),
         {:ok, state} <- send_node(Receiver.failure_ack(node, credentials), state) do
      send(state.owner, {:connection_event, {:credentials, credentials}})
      {:ok, state}
    end
  end

  defp track_incoming_retry(key, state) do
    counts = Map.get(state, :incoming_retry_counts, %{})
    previous = Map.get(counts, key, 0)
    max_retry_count = Map.get(state, :max_retry_count, @default_max_retry_count)
    total = Map.get(state, :incoming_retry_total, 0)
    budget = Map.get(state, :incoming_retry_budget, @default_incoming_retry_budget)

    if previous >= max_retry_count or total >= budget do
      {previous, false, state}
    else
      count = previous + 1
      order = Map.get(state, :incoming_retry_order, [])
      order = if previous == 0, do: order ++ [key], else: order
      counts = Map.put(counts, key, count)
      {counts, order} = trim_incoming_retries(counts, order, state)

      state =
        state
        |> Map.put(:incoming_retry_counts, counts)
        |> Map.put(:incoming_retry_order, order)
        |> Map.put(:incoming_retry_total, total + 1)

      {count, true, state}
    end
  end

  defp trim_incoming_retries(counts, order, state) do
    limit = Map.get(state, :incoming_retry_limit, @default_sent_message_limit)
    overflow = max(length(order) - limit, 0)
    {expired, order} = Enum.split(order, overflow)
    {Map.drop(counts, expired), order}
  end

  defp clear_incoming_retry(node, state) do
    key = {node.attrs["id"], node.attrs["participant"] || node.attrs["from"]}
    counts = Map.delete(Map.get(state, :incoming_retry_counts, %{}), key)
    order = List.delete(Map.get(state, :incoming_retry_order, []), key)

    state
    |> Map.put(:incoming_retry_counts, counts)
    |> Map.put(:incoming_retry_order, order)
  end

  defp incoming_retry_receipt(_node, _count, false, credentials), do: {nil, credentials}

  defp incoming_retry_receipt(node, count, true, credentials) do
    attrs =
      %{"id" => node.attrs["id"], "type" => "retry", "to" => node.attrs["from"]}
      |> copy_node_attr(node.attrs, "recipient")
      |> copy_node_attr(node.attrs, "participant")

    content = [
      %Node{
        tag: "retry",
        attrs: %{
          "count" => Integer.to_string(count),
          "error" => "0",
          "id" => node.attrs["id"],
          "t" => node.attrs["t"],
          "v" => "1"
        }
      },
      %Node{tag: "registration", content: encode_retry_integer(credentials.registration_id, 4)}
    ]

    {content, credentials} = maybe_add_retry_keys(content, credentials, count)
    {%Node{tag: "receipt", attrs: attrs, content: content}, credentials}
  end

  defp maybe_add_retry_keys(content, credentials, count) when count <= 1,
    do: {content, credentials}

  defp maybe_add_retry_keys(content, credentials, _count) do
    if map_size(credentials.pre_keys) >= @default_max_persisted_pre_keys do
      {content, credentials}
    else
      {credentials, upload, last_id} = PreKeys.upload_node(credentials, 1)
      credentials = %{credentials | first_unuploaded_pre_key_id: last_id + 1}
      list = NodeUtils.child(upload, "list")

      key_content = [
        NodeUtils.child(upload, "type"),
        NodeUtils.child(upload, "identity"),
        NodeUtils.child(list, "key"),
        NodeUtils.child(upload, "skey")
      ]

      key_content =
        if credentials.account do
          key_content ++
            [%Node{tag: "device-identity", content: Protobuf.encode(credentials.account)}]
        else
          key_content
        end

      {content ++ [%Node{tag: "keys", content: key_content}], credentials}
    end
  end

  defp maybe_send_retry(nil, state), do: {:ok, state}
  defp maybe_send_retry(retry, state), do: send_node(retry, state)

  defp copy_node_attr(attrs, source, key) do
    case source[key] do
      nil -> attrs
      value -> Map.put(attrs, key, value)
    end
  end

  defp encode_retry_integer(value, bytes),
    do: <<value::unsigned-big-integer-size(bytes)-unit(8)>>

  defp acknowledge_message(credentials, protocol_response, state) do
    with :ok <- persist_credentials(state.session_path, credentials),
         {:ok, state} <-
           send_node(protocol_response, %{
             state
             | credentials: credentials
           }) do
      send(state.owner, {:connection_event, {:credentials, credentials}})
      {:ok, state}
    end
  end

  defp acknowledge_history(envelope, state) do
    case {HistorySync.receipt(envelope), HistorySync.detect(envelope.content)} do
      {%Node{} = receipt, {:ok, notification}} ->
        encoded = Protobuf.encode(notification)

        with {:ok, state} <-
               update_credentials(state, fn credentials ->
                 pending = Enum.uniq(credentials.pending_history_sync ++ [encoded])
                 %{credentials | pending_history_sync: pending}
               end) do
          send_node(receipt, state)
        end

      {nil, _not_history} ->
        {:ok, state}

      _other ->
        {:ok, state}
    end
  end

  defp schedule_initial_app_state(envelope, state) do
    initial? =
      envelope.key.from_me and match?({:ok, _notification}, HistorySync.detect(envelope.content)) and
        map_size(state.credentials.app_state_collections) == 0 and
        state.credentials.pending_app_state_sync == []

    if initial? do
      update_credentials(state, fn credentials ->
        %{credentials | pending_app_state_sync: @app_state_collections}
      end)
    else
      {:ok, state}
    end
  end

  defp handle_receipt(node, state) do
    if node.attrs["type"] == "retry" do
      handle_retry_receipt(node, state)
    else
      handle_status_receipt(node, state)
    end
  end

  defp handle_status_receipt(node, state) do
    projection =
      try do
        project_receipt_statuses(node, state)
        :ok
      rescue
        error -> {:error, error}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    if match?({:error, _reason}, projection) do
      {:error, reason} = projection
      send(state.owner, {:connection_event, {:error, {:receipt_projection_failed, reason}}})
    end

    send_node(Receiver.ack(node, state.credentials), state)
  end

  defp handle_retry_receipt(node, state) do
    requester = node.attrs["participant"] || node.attrs["from"] || node.attrs["to"]
    ids = Receiver.receipt_ids(node)
    bundle = retry_bundle(node)
    registration = USync.parse_retry_registration(node)
    wire_count = retry_wire_count(node)

    {state, diagnostics} =
      cond do
        not is_binary(requester) ->
          {state, [:invalid_retry_requester]}

        ids == [] ->
          {state, [:missing_retry_id]}

        true ->
          ids
          |> Enum.reduce({state, [], bundle}, fn id, {state, diagnostics, bundle} ->
            case safe_retry_message(
                   id,
                   requester,
                   wire_count,
                   bundle,
                   registration,
                   state
                 ) do
              {:ok, state, bundle_used?} ->
                {state, diagnostics, consume_retry_bundle(bundle, bundle_used?)}

              {:error, reason, state, bundle_used?} ->
                {state, [reason | diagnostics], consume_retry_bundle(bundle, bundle_used?)}
            end
          end)
          |> then(fn {state, diagnostics, _bundle} -> {state, diagnostics} end)
      end

    Enum.each(Enum.reverse(diagnostics), &emit_retry_diagnostic(state, &1))
    send_node(Receiver.ack(node, state.credentials), state)
  end

  defp safe_retry_message(id, requester, wire_count, bundle, registration, state) do
    retry_message(id, requester, wire_count, bundle, registration, state)
  rescue
    _error -> {:error, :invalid_retry_stanza, state, false}
  catch
    _kind, _reason -> {:error, :invalid_retry_stanza, state, false}
  end

  defp retry_message(id, requester, wire_count, bundle, registration, state) do
    sent_messages = Map.get(state, :sent_messages, %{})
    retry_counts = Map.get(state, :retry_counts, %{})
    max_count = Map.get(state, :max_retry_count, @default_max_retry_count)

    with {:ok, material} <- Map.fetch(sent_messages, id),
         {:ok, normalized_requester} <-
           Sender.retry_requester(material, requester, state.credentials) do
      key = {id, normalized_requester}
      count = Map.get(retry_counts, key, 0)

      cond do
        count >= max_count ->
          {:error, :retry_limit_reached, state, false}

        new_retry_requester?(retry_counts, key) and
            retry_requester_count(retry_counts, id) >=
              Map.get(state, :max_retry_requesters, @default_max_retry_requesters) ->
          {:error, :retry_requester_limit_reached, state, false}

        true ->
          retry_counts = Map.put(retry_counts, key, count + 1)
          state = Map.put(state, :retry_counts, retry_counts)

          resend_message(
            id,
            material,
            normalized_requester,
            wire_count,
            bundle,
            registration,
            state
          )
      end
    else
      :error -> {:error, :sent_message_not_found, state, false}
      {:error, reason} -> {:error, reason, state, false}
    end
  end

  defp resend_message(id, material, requester, wire_count, bundle, registration, state) do
    with {:ok, bundle} <- bundle,
         {:ok, registration} <- registration do
      bundle_used? = not is_nil(bundle)

      case Sender.retry_stanza(
             id,
             material,
             requester,
             wire_count,
             state.credentials,
             bundle,
             registration
           ) do
        {:ok, stanza, credentials} ->
          send_retry_stanza(stanza, credentials, state, bundle_used?)

        {:error, reason} ->
          {:error, reason, state, bundle_used?}
      end
    else
      {:error, reason} -> {:error, reason, state, false}
    end
  end

  defp send_retry_stanza(stanza, credentials, state, bundle_used?) do
    candidate_state = %{state | credentials: credentials}

    case persist_credentials(candidate_state.session_path, credentials) do
      :ok ->
        send(candidate_state.owner, {:connection_event, {:credentials, credentials}})

        case send_node(stanza, candidate_state) do
          {:ok, sent_state} -> {:ok, sent_state, bundle_used?}
          {:error, reason} -> {:error, reason, candidate_state, bundle_used?}
        end

      {:error, reason} ->
        {:error, {:store, reason}, state, bundle_used?}
    end
  end

  defp retry_bundle(receipt) do
    case USync.parse_retry_bundle(receipt) do
      :none -> {:ok, nil}
      {:ok, bundle} -> {:ok, bundle}
      {:error, reason} -> {:error, reason}
    end
  end

  defp consume_retry_bundle({:ok, bundle}, true) when not is_nil(bundle), do: {:ok, nil}
  defp consume_retry_bundle(bundle, _used?), do: bundle

  defp retry_wire_count(receipt) do
    with %Node{} = retry <- NodeUtils.child(receipt, "retry"),
         {count, ""} when count > 0 <- Integer.parse(retry.attrs["count"] || "") do
      count
    else
      _missing_or_invalid -> 1
    end
  end

  defp new_retry_requester?(retry_counts, key), do: not Map.has_key?(retry_counts, key)

  defp retry_requester_count(retry_counts, id) do
    Enum.count(retry_counts, fn {{message_id, _requester}, _count} -> message_id == id end)
  end

  defp emit_retry_diagnostic(state, reason) do
    Logger.warning("retry receipt not resent", reason: reason)

    if diagnostic_sender = Map.get(state, :diagnostic_sender) do
      diagnostic_sender.({:retry_unsupported, reason})
    end
  end

  defp process_and_ack(node, state, process) do
    result =
      try do
        process.()
      rescue
        error -> {:error, error}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, updated_state} ->
        send_node(Receiver.ack(node, updated_state.credentials), updated_state)

      {:defer_ack, updated_state} ->
        {:ok, updated_state}

      {:error, reason} ->
        case send_node(Receiver.ack(node, state.credentials), state) do
          {:ok, _state} -> {:error, reason}
          {:error, ack_reason} -> {:error, {:ack_failed, ack_reason, reason}}
        end
    end
  end

  defp project_receipt_statuses(node, state) do
    status = Receiver.receipt_status(node.attrs["type"])

    if status != :ignore do
      at = Receiver.receipt_timestamp(node, receipt_clock(state))
      to = node.attrs["from"] || node.attrs["to"]
      ids = Receiver.receipt_ids(node)

      if Receiver.user_receipt?(node, state.credentials) do
        updates =
          Enum.flat_map(ids, fn id ->
            case Receiver.user_receipt(node, status, at) do
              nil ->
                []

              receipt ->
                [
                  %{
                    key: Receiver.receipt_key(node, id, state.credentials),
                    receipt: receipt
                  }
                ]
            end
          end)

        if updates != [] do
          send(state.owner, {:connection_event, {:message_receipt_update, updates}})
        end
      else
        Enum.each(ids, fn id ->
          send(state.owner, {:connection_event, {:message_status, id, to, status, at, nil}})
        end)

        updates =
          Enum.map(ids, fn id ->
            %{
              key: Receiver.receipt_key(node, id, state.credentials),
              update: %{status: status, timestamp: at, error: nil}
            }
          end)

        if updates != [] do
          send(state.owner, {:connection_event, {:messages_update, updates}})
        end
      end
    end
  end

  defp receipt_clock(state), do: Map.get(state, :now, &DateTime.utc_now/0)

  defp failed_ack_key(node, id, state) do
    key = Receiver.receipt_key(node, id, state.credentials)

    case sent_message_recipient(id, state) do
      recipient when is_binary(recipient) -> %{key | remote_jid: recipient, from_me: true}
      _missing -> key
    end
  end

  defp failed_ack_recipient(node, id, state) do
    sent_message_recipient(id, state) || node.attrs["from"] || node.attrs["to"]
  end

  defp sent_message_recipient(id, state), do: get_in(state, [:sent_messages, id, :recipient])

  defp remember_sent_message(state, %Node{attrs: %{"id" => id}}, retry_material)
       when is_binary(id) and is_map(retry_material) do
    limit = Map.get(state, :sent_message_limit, @default_sent_message_limit)
    order = [id | Enum.reject(Map.get(state, :sent_message_order, []), &(&1 == id))]
    order = Enum.take(order, max(limit, 0))

    messages =
      state
      |> Map.get(:sent_messages, %{})
      |> Map.put(id, retry_material)
      |> Map.take(order)

    byte_limit = Map.get(state, :sent_message_byte_limit, @default_sent_message_bytes)
    {order, messages, bytes} = trim_sent_messages(order, messages, max(byte_limit, 0))

    retry_counts =
      state
      |> Map.get(:retry_counts, %{})
      |> Map.reject(fn {{message_id, _requester}, _count} -> message_id not in order end)

    state
    |> Map.put(:sent_messages, messages)
    |> Map.put(:sent_message_order, order)
    |> Map.put(:sent_message_bytes, bytes)
    |> Map.put(:retry_counts, retry_counts)
  end

  defp remember_sent_message(state, _node, _retry_material), do: state

  defp trim_sent_messages(order, messages, byte_limit) do
    bytes =
      Enum.reduce(messages, 0, fn {_id, material}, total -> total + material_size(material) end)

    if bytes > byte_limit and order != [] do
      oldest = List.last(order)
      trim_sent_messages(Enum.drop(order, -1), Map.delete(messages, oldest), byte_limit)
    else
      {order, messages, bytes}
    end
  end

  defp material_size(%{recipient: recipient, text: text}) do
    byte_size(recipient) + byte_size(text)
  end

  defp material_size(_material), do: 0

  defp redact_status_field(state, field) do
    if Map.has_key?(state, field), do: Map.put(state, field, :redacted), else: state
  end

  defp decrypt_signal("pkmsg", record, ciphertext, credentials) do
    SessionCipher.decrypt_pre_key(record, ciphertext, credentials)
  end

  defp decrypt_signal("msg", nil, _ciphertext, _credentials), do: {:error, :missing_session}

  defp decrypt_signal("msg", record, ciphertext, credentials) do
    case SessionCipher.decrypt(record, ciphertext, credentials) do
      {:ok, plaintext, record} -> {:ok, plaintext, record, nil}
      error -> error
    end
  end

  defp decrypt_signal(type, _record, _ciphertext, _credentials),
    do: {:error, {:unsupported_encryption, type}}

  defp unpad_message(<<>>), do: {:error, :invalid_padding}

  defp unpad_message(plaintext) do
    padding = :binary.last(plaintext)

    if padding in 1..16 and padding <= byte_size(plaintext) do
      {:ok, binary_part(plaintext, 0, byte_size(plaintext) - padding)}
    else
      {:error, :invalid_padding}
    end
  end

  defp normalize_signal_address(jid) do
    case BaileysExo.JID.decode(jid) do
      {:ok, decoded} -> BaileysExo.JID.encode(decoded.user, decoded.server, decoded.device)
      {:error, :invalid_jid} -> jid
    end
  end

  defp persist_credentials(nil, _credentials), do: :ok
  defp persist_credentials(path, credentials), do: FileStore.save(path, credentials)

  defp close_transport(transport) do
    if Process.alive?(transport) do
      WebSocket.close(transport)
    end
  catch
    :exit, _reason -> :ok
  end

  defp schedule_keepalive(state) do
    cancel_timer(state.keepalive_timer)
    %{state | keepalive_timer: Process.send_after(self(), :keepalive, 30_000)}
  end
end
