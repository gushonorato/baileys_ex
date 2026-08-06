defmodule HelloWorld do
  use Baileys

  def start_link(phone) do
    Baileys.start_link(__MODULE__, phone,
      session: "hello_world",
      store: {Baileys.Store.File, root: Path.expand("baileys_sessions", __DIR__)}
    )
  end

  @impl Baileys
  def init(phone) do
    case Baileys.jid(phone) do
      {:ok, _jid} -> {:ok, %{phone: phone}}
      {:error, reason} -> {:stop, {:invalid_phone, reason}}
    end
  end

  @impl Baileys
  def handle_event(%Baileys.Event{type: :qr, data: %Baileys.QR{} = qr}, state) do
    IO.puts("Scan this QR code in WhatsApp > Linked devices:")
    render_qr(qr.payload)
    {:noreply, state}
  end

  def handle_event(
        %Baileys.Event{
          client: client,
          type: :connection,
          data: %Baileys.Connection{state: :online}
        },
        state
      ) do
    case Baileys.send_text(client, state.phone, "Hello World") do
      {:ok, message} ->
        IO.puts(
          "Submitted Hello World to #{message.to} (id: #{message.id}); waiting for delivery..."
        )

        {:noreply, Map.put(state, :message_id, message.id)}

      {:error, reason} ->
        {:stop, {:send_failed, reason}, state}
    end
  end

  def handle_event(%Baileys.Event{type: :paired, data: account}, state) do
    IO.puts("Paired as #{account.jid || "unknown"}; reconnecting...")
    {:noreply, state}
  end

  def handle_event(
        %Baileys.Event{type: :disconnected, data: %{reason: :restart_required}},
        state
      ) do
    {:noreply, state}
  end

  def handle_event(%Baileys.Event{type: :connection, data: connection}, state) do
    IO.puts("Connection: #{connection.state}")
    {:noreply, state}
  end

  def handle_event(
        %Baileys.Event{type: :message_status, data: %{id: id, status: status}},
        %{message_id: id} = state
      )
      when status in [:delivered, :read, :played] do
    IO.puts("Message #{id}: #{status}")
    {:stop, :normal, state}
  end

  def handle_event(
        %Baileys.Event{type: :message_status, data: %{id: id, status: :failed} = status},
        %{message_id: id} = state
      ) do
    {:stop, {:message_failed, id, status.error}, state}
  end

  def handle_event(%Baileys.Event{type: :message_status, data: status}, state) do
    IO.puts("Message #{status.id}: #{status.status}")
    {:noreply, state}
  end

  def handle_event(%Baileys.Event{type: :error, data: error}, state) do
    IO.puts(:stderr, "Protocol error: #{error.message}")
    {:noreply, state}
  end

  def handle_event(_event, state), do: {:noreply, state}

  defp render_qr(payload) do
    {:ok, qr} = QRCode.create(payload, :low)
    quiet_zone = List.duplicate(0, 2)
    width = length(qr.matrix) + 4
    blank = List.duplicate(0, width)

    matrix =
      [blank, blank] ++ Enum.map(qr.matrix, &(quiet_zone ++ &1 ++ quiet_zone)) ++ [blank, blank]

    matrix
    |> Enum.chunk_every(2, 2, [blank])
    |> Enum.each(fn [top, bottom] ->
      line =
        Enum.zip(top, bottom)
        |> Enum.map_join(fn
          {0, 0} -> " "
          {1, 0} -> "▀"
          {0, 1} -> "▄"
          {1, 1} -> "█"
        end)

      IO.puts(line)
    end)
  end
end

case System.argv() do
  [phone] ->
    case HelloWorld.start_link(phone) do
      {:ok, pid} ->
        reference = Process.monitor(pid)

        receive do
          {:DOWN, ^reference, :process, ^pid, :normal} ->
            :ok

          {:DOWN, ^reference, :process, ^pid, reason} ->
            IO.puts(:stderr, "HelloWorld stopped: #{inspect(reason)}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Could not start: #{inspect(reason)}")
        System.halt(1)
    end

  _arguments ->
    IO.puts(:stderr, "Usage: mix run examples/hello_world.exs <phone>")
    System.halt(1)
end
