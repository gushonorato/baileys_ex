defmodule BaileysExo.Client do
  @moduledoc false

  use GenServer

  alias Baileys.{Account, Connection, Disconnected, Error, MessageStatus, QR, TextMessage}
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
        case FileStore.save(state.session_path, credentials) do
          :ok -> {:reply, {:ok, sent}, %{state | credentials: credentials}}
          {:error, reason} -> {:reply, {:error, {:store, reason}}, state}
        end

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
    case FileStore.save(state.session_path, credentials) do
      :ok ->
        {:noreply, %{state | credentials: credentials}}

      {:error, reason} ->
        notify(state, {:error, %Error{message: "could not save credentials: #{inspect(reason)}"}})
        {:noreply, state}
    end
  end

  def handle_info({:connection_event, {:paired, me}}, state) do
    notify(state, {:paired, %Account{jid: me.id, name: me[:name]}})
    {:noreply, %{state | status: :restarting}}
  end

  def handle_info({:connection_event, {:text_message, metadata, text}}, state) do
    message = %TextMessage{
      id: metadata.id,
      chat_jid: metadata.chat_jid,
      sender_jid: metadata.sender_jid,
      from_me: metadata.from_me,
      text: text,
      timestamp: DateTime.from_unix!(metadata.timestamp),
      offline?: metadata.offline
    }

    notify(state, {:text_message, message})
    {:noreply, state}
  end

  def handle_info({:connection_event, {:message_status, id, to, status, error}}, state) do
    notify(state, {
      :message_status,
      %MessageStatus{id: id, to: to, status: status, at: DateTime.utc_now(), error: error}
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
