defmodule BaileysExo.Transport.WebSocket do
  @moduledoc false

  use GenServer

  @host "web.whatsapp.com"
  @path "/ws/chat"

  def start_link(owner, options \\ []) do
    GenServer.start_link(__MODULE__, {owner, options})
  end

  def send_binary(transport, data), do: GenServer.call(transport, {:send, {:binary, data}})
  def close(transport), do: GenServer.call(transport, :close)

  @impl true
  def init({owner, options}) do
    Process.flag(:trap_exit, true)
    send(self(), :connect)

    {:ok,
     %{
       owner: owner,
       options: options,
       conn: nil,
       request_ref: nil,
       websocket: nil,
       status: nil,
       headers: []
     }}
  end

  @impl true
  def handle_info(:connect, state) do
    transport_options = [
      cacertfile: CAStore.file_path(),
      server_name_indication: ~c"web.whatsapp.com"
    ]

    with {:ok, conn} <-
           Mint.HTTP.connect(:https, @host, 443,
             protocols: [:http1],
             transport_opts: transport_options
           ),
         path = path(state.options),
         {:ok, conn, request_ref} <-
           Mint.WebSocket.upgrade(:wss, conn, path, [{"origin", "https://web.whatsapp.com"}]) do
      {:noreply, %{state | conn: conn, request_ref: request_ref}}
    else
      {:error, reason} -> stop_with_error(reason, state)
      {:error, _conn, reason} -> stop_with_error(reason, state)
    end
  end

  def handle_info(message, %{conn: nil} = state) do
    send(state.owner, {:transport_error, {:unexpected_message, message}})
    {:noreply, state}
  end

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      :unknown ->
        {:noreply, state}

      {:ok, conn, responses} ->
        process_responses(responses, %{state | conn: conn})

      {:error, conn, reason, responses} ->
        {_reply, state} = process_responses(responses, %{state | conn: conn})
        stop_with_error(reason, state)
    end
  end

  @impl true
  def handle_call({:send, _frame}, _from, %{websocket: nil} = state) do
    {:reply, {:error, :not_open}, state}
  end

  def handle_call({:send, frame}, _from, state) do
    with {:ok, websocket, encoded} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, encoded) do
      {:reply, :ok, %{state | conn: conn, websocket: websocket}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:error, conn, reason} -> {:reply, {:error, reason}, %{state | conn: conn}}
    end
  end

  def handle_call(:close, _from, %{websocket: nil} = state), do: {:stop, :normal, :ok, state}

  def handle_call(:close, _from, state) do
    with {:ok, websocket, encoded} <- Mint.WebSocket.encode(state.websocket, :close),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, encoded) do
      {:stop, :normal, :ok, %{state | conn: conn, websocket: websocket}}
    else
      _error -> {:stop, :normal, :ok, state}
    end
  end

  @impl true
  def terminate(_reason, %{conn: nil}), do: :ok

  def terminate(_reason, state) do
    Mint.HTTP.close(state.conn)
    :ok
  end

  defp process_responses([], state), do: {:noreply, state}

  defp process_responses([response | responses], state) do
    case response do
      {:status, request_ref, status} when request_ref == state.request_ref ->
        process_responses(responses, %{state | status: status})

      {:headers, request_ref, headers} when request_ref == state.request_ref ->
        process_responses(responses, %{state | headers: headers})

      {:done, request_ref} when request_ref == state.request_ref ->
        case Mint.WebSocket.new(state.conn, request_ref, state.status, state.headers) do
          {:ok, conn, websocket} ->
            send(state.owner, {:transport_open, self()})
            process_responses(responses, %{state | conn: conn, websocket: websocket})

          {:error, conn, reason} ->
            stop_with_error(reason, %{state | conn: conn})
        end

      {:data, request_ref, data} when request_ref == state.request_ref ->
        with {:ok, websocket, frames} <- Mint.WebSocket.decode(state.websocket, data),
             {:ok, state} <- process_frames(frames, %{state | websocket: websocket}) do
          process_responses(responses, state)
        else
          {:error, reason} -> stop_with_error(reason, state)
          {:error, websocket, reason} -> stop_with_error(reason, %{state | websocket: websocket})
        end

      _other ->
        process_responses(responses, state)
    end
  end

  defp process_frames([], state), do: {:ok, state}

  defp process_frames([{:binary, data} | frames], state) do
    send(state.owner, {:transport_binary, data})
    process_frames(frames, state)
  end

  defp process_frames([{:ping, data} | frames], state) do
    with {:ok, websocket, encoded} <- Mint.WebSocket.encode(state.websocket, {:pong, data}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, encoded) do
      process_frames(frames, %{state | conn: conn, websocket: websocket})
    end
  end

  defp process_frames([:close | _frames], state) do
    send(state.owner, {:transport_closed, :remote})
    {:ok, state}
  end

  defp process_frames([{:close, code, reason} | _frames], state) do
    send(state.owner, {:transport_closed, {code, reason}})
    {:ok, state}
  end

  defp process_frames([{:error, reason} | _frames], _state), do: {:error, reason}

  defp process_frames([_frame | frames], state), do: process_frames(frames, state)

  defp path(options) do
    case Keyword.get(options, :routing_info) do
      nil -> @path
      routing_info -> @path <> "?ED=" <> Base.url_encode64(routing_info, padding: false)
    end
  end

  defp stop_with_error(reason, state) do
    send(state.owner, {:transport_error, reason})
    {:stop, {:transport_error, reason}, state}
  end
end
