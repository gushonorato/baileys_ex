defmodule BaileysExo.ConnectionProcess do
  @moduledoc false

  use GenServer

  require Logger

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.{Codec, Node, NodeUtils}
  alias BaileysExo.{Crypto, Noise}
  alias BaileysExo.Protocol.Handshake
  alias BaileysExo.Protocol.{Pairing, USync}
  alias BaileysExo.Proto.Message
  alias BaileysExo.Messages.{Receiver, Sender}
  alias BaileysExo.Signal.SessionCipher
  alias BaileysExo.Signal.PreKeys
  alias BaileysExo.Store.File, as: FileStore
  alias BaileysExo.Transport.WebSocket

  @default_max_retry_count 5
  @default_max_retry_requesters 16
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

  def commit_credentials(connection, credentials) do
    GenServer.call(connection, {:commit_credentials, credentials}, 30_000)
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

      {{_kind, _credentials, _metadata, _timer}, pending} ->
        stop_with_error({:query_timeout, id}, %{state | pending_queries: pending})

      {{_kind, _credentials, _timer}, pending} ->
        stop_with_error({:query_timeout, id}, %{state | pending_queries: pending})
    end
  end

  def handle_info({:EXIT, transport, reason}, %{transport: transport} = state) do
    stop_with_error(reason, state)
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

  def handle_call({:commit_credentials, credentials}, _from, state) do
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
            send(state.owner, {:connection_event, {:connection, :online}})

            {:ok,
             schedule_keepalive(%{state | credentials: credentials, pending_queries: pending})}
          end
        else
          {:error, {:prekey_upload_failed, node}}
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
        {:ok, text, credentials, metadata, receipt_attrs} ->
          with {:ok, state} <- acknowledge_message(credentials, receipt_attrs, state) do
            send(state.owner, {:connection_event, {:text_message, metadata, text}})
            {:ok, state}
          end

        {:ignored, credentials, receipt_attrs} ->
          acknowledge_message(credentials, receipt_attrs, state)

        {:error, reason} ->
          send(state.owner, {:connection_event, {:error, {:message_decrypt_failed, reason}}})
          send_node(Receiver.failure_ack(node, state.credentials), state)
      end
    else
      send_node(Receiver.ack(node, state.credentials), state)
    end
  end

  defp handle_node(%Node{tag: "ack", attrs: %{"class" => "message", "id" => id}} = node, state) do
    if node.attrs["error"] do
      send(state.owner, {
        :connection_event,
        {:message_status, id, node.attrs["from"] || node.attrs["to"], :failed,
         Receiver.receipt_timestamp(node, receipt_clock(state)), node.attrs}
      })
    end

    {:ok, state}
  end

  defp handle_node(%Node{tag: "receipt"} = node, state), do: handle_receipt(node, state)

  defp handle_node(%Node{tag: "call"} = node, state) do
    process_and_ack(node, state, fn -> {:ok, state} end)
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
    if NodeUtils.child(node, "link_code_companion_reg") do
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
    else
      {:ok, state}
    end
  end

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
    if state.credentials.first_unuploaded_pre_key_id == 1 do
      {credentials, node, last_id} = PreKeys.upload_node(state.credentials)

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
      send(state.owner, {:connection_event, {:connection, :online}})
      {:ok, schedule_keepalive(state)}
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
          {:prekeys, credentials, last_id} -> {:prekeys, credentials, last_id, timer}
          {:pairing_finish, credentials} -> {:pairing_finish, credentials, timer}
        end

      {:ok, %{state | pending_queries: Map.put(state.pending_queries, id, pending_entry)}}
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
    encrypted = NodeUtils.child(node, "enc")

    with {:ok, context} <- Receiver.context(node, credentials),
         %Node{content: ciphertext} <- encrypted,
         true <- is_binary(ciphertext),
         address <- normalize_signal_address(context.signal_jid),
         record <- credentials.sessions[address],
         {:ok, plaintext, record, used_pre_key} <-
           decrypt_signal(encrypted.attrs["type"], record, ciphertext, credentials),
         {:ok, unpadded} <- unpad_message(plaintext),
         message <- Message.decode(unpadded),
         message <- (message.deviceSentMessage && message.deviceSentMessage.message) || message do
      credentials = put_in(credentials.sessions[address], record)

      credentials =
        if used_pre_key,
          do: %{credentials | pre_keys: Map.delete(credentials.pre_keys, used_pre_key)},
          else: credentials

      case Receiver.extract_text(message) do
        {:ok, text} ->
          metadata = %{
            id: context.id,
            chat_jid: context.chat_jid,
            sender_jid: context.sender_jid,
            from_me: context.from_me,
            timestamp: context.timestamp,
            offline: context.offline
          }

          {:ok, text, credentials, metadata, context.receipt_attrs}

        :unsupported ->
          {:ignored, credentials, context.receipt_attrs}
      end
    else
      nil -> {:error, :missing_encrypted_message}
      false -> {:error, :invalid_encrypted_message}
      {:error, _reason} = error -> error
      _invalid -> {:error, :unsupported_message}
    end
  rescue
    error -> {:error, error}
  end

  defp acknowledge_message(credentials, receipt_attrs, state) do
    with :ok <- persist_credentials(state.session_path, credentials),
         {:ok, state} <-
           send_node(%Node{tag: "receipt", attrs: receipt_attrs}, %{
             state
             | credentials: credentials
           }) do
      send(state.owner, {:connection_event, {:credentials, credentials}})
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

      Enum.each(Receiver.receipt_ids(node), fn id ->
        send(state.owner, {:connection_event, {:message_status, id, to, status, at, nil}})
      end)
    end
  end

  defp receipt_clock(state), do: Map.get(state, :now, &DateTime.utc_now/0)

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
