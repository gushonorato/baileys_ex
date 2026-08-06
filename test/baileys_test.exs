defmodule BaileysTest.Handler do
  use Baileys

  @impl Baileys
  def init(owner), do: {:ok, %{owner: owner, events: 0}}

  @impl Baileys
  def handle_event(%Baileys.Event{} = event, state) do
    send(state.owner, {:callback_event, event, Baileys.status(event.client)})
    {:noreply, %{state | events: state.events + 1}}
  end
end

defmodule BaileysTest do
  use ExUnit.Case, async: true

  test "starts like a GenServer and delivers typed callback events" do
    sessions_path =
      Path.join(System.tmp_dir!(), "baileys-behaviour-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(sessions_path) end)

    assert {:ok, server} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               session: "callback",
               sessions_path: sessions_path
             )

    assert Baileys.status(server) == :disconnected
    assert File.exists?(Path.join(sessions_path, "callback.json"))
    client = :sys.get_state(server).client
    qr = %Baileys.QR{payload: "payload"}
    send(server, {:baileys, client, {:qr, qr}})

    assert_receive {:callback_event, %Baileys.Event{client: ^client, type: :qr, data: ^qr},
                    :disconnected}
  end

  test "normalizes phone numbers through the Baileys facade" do
    assert Baileys.jid("+55 (21) 98639-9132") ==
             {:ok, "5521986399132@s.whatsapp.net"}
  end

  test "delivers the original disconnect reason and code in the callback event" do
    sessions_path =
      Path.join(System.tmp_dir!(), "baileys-disconnect-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(sessions_path) end)

    assert {:ok, server} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               session: "disconnect-callback",
               sessions_path: sessions_path
             )

    client = :sys.get_state(server).client
    connection = spawn(fn -> Process.sleep(:infinity) end)

    :sys.replace_state(client, fn state ->
      %{
        state
        | connection: connection,
          connection_monitor: Process.monitor(connection),
          status: :online
      }
    end)

    Process.exit(connection, {:shutdown, {:disconnected, :logged_out, 401}})

    assert_receive {:callback_event,
                    %Baileys.Event{
                      client: ^client,
                      type: :disconnected,
                      data: %Baileys.Disconnected{reason: :logged_out, code: 401}
                    }, :disconnected}

    refute_receive {:callback_event, %Baileys.Event{type: :error}, _status}
  end

  test "requires an absolute sessions path" do
    assert {:error, :sessions_path_required} =
             Baileys.start_link(BaileysTest.Handler, self(), connect: false)

    assert {:error, :sessions_path_must_be_absolute} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               sessions_path: "relative/sessions"
             )
  end
end
