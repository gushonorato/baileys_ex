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
    root =
      Path.join(System.tmp_dir!(), "baileys-behaviour-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, server} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               session: "callback",
               store: {Baileys.Store.File, root: root}
             )

    assert Baileys.status(server) == :disconnected
    assert File.exists?(Path.join(root, "callback.json"))
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
    assert {:ok, server} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               session: "disconnect-callback",
               store: {Baileys.Store.Memory, []}
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

  test "uses the default session and preserves session validation" do
    root = Path.join(System.tmp_dir!(), "baileys-default-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, server} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               store: {Baileys.Store.File, root: root}
             )

    assert File.exists?(Path.join(root, "default.json"))
    GenServer.stop(server)

    assert {:error, :invalid_session} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               session: "../unsafe",
               store: {Baileys.Store.Memory, []}
             )
  end

  test "requires an explicit valid store and rejects sessions_path" do
    assert {:error, :store_required} =
             Baileys.start_link(BaileysTest.Handler, self(), connect: false)

    assert {:error, :invalid_store} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               store: Baileys.Store.Memory
             )

    assert {:error, :invalid_store} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               store: {String, []}
             )

    assert {:error, {:unsupported_option, :sessions_path}} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               store: {Baileys.Store.Memory, []},
               sessions_path: "/tmp/unsupported"
             )

    assert {:error, {:store, :root_must_be_absolute}} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               store: {Baileys.Store.File, root: "relative/sessions"}
             )
  end
end
