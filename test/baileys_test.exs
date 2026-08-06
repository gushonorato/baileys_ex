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

defmodule BaileysTest.FakeConnection do
  use GenServer

  def start_link(owner, _credentials, _options), do: GenServer.start_link(__MODULE__, owner)
  def close(connection), do: GenServer.call(connection, :close)

  @impl true
  def init(owner) do
    send(owner, {:connection_event, {:connection, :connecting}})
    send(owner, {:connection_event, {:qr, "fresh-qr"}})
    {:ok, %{}}
  end

  @impl true
  def handle_call(:close, _from, state), do: {:stop, :normal, :ok, state}
end

defmodule BaileysTest.ResetFailureStore do
  @behaviour Baileys.Store.Adapter

  @impl true
  def init(_options), do: {:ok, nil}

  @impl true
  def fetch(_state, _session), do: :not_found

  @impl true
  def put(_state, _session, _payload), do: :ok

  @impl true
  def delete(_state, _session), do: {:error, :read_only}
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

  test "requires a valid store and preserves sessions_path compatibility" do
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

    root = Path.join(System.tmp_dir!(), "baileys-legacy-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, legacy} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               session: "legacy",
               sessions_path: root
             )

    assert File.exists?(Path.join(root, "legacy.json"))
    GenServer.stop(legacy)

    assert {:error, :sessions_path_must_be_absolute} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               sessions_path: "relative/sessions"
             )

    assert {:error, {:store, :root_must_be_absolute}} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               store: {Baileys.Store.File, root: "relative/sessions"}
             )
  end

  test "reset_session stops the current connection and installs fresh credentials" do
    assert {:ok, server} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               store: {Baileys.Store.Memory, []}
             )

    client = :sys.get_state(server).client
    original = :sys.get_state(client).credentials
    {:ok, connection} = BaileysTest.FakeConnection.start_link(self(), original, [])
    external_monitor = Process.monitor(connection)

    :sys.replace_state(client, fn state ->
      %{
        state
        | connection: connection,
          connection_monitor: Process.monitor(connection),
          status: :online,
          options: Keyword.put(state.options, :connection_module, BaileysTest.FakeConnection)
      }
    end)

    assert :ok = Baileys.reset_session(server, reconnect: false)
    assert_receive {:DOWN, ^external_monitor, :process, ^connection, :normal}

    reset = :sys.get_state(client)
    refute reset.credentials == original
    assert reset.connection == nil
    assert Baileys.status(server) == :disconnected
    assert Process.alive?(server)
  end

  test "reset_session reconnects by default and emits a new QR" do
    assert {:ok, client} =
             Baileys.Client.start(
               owner: self(),
               store: {Baileys.Store.Memory, []},
               connection_module: BaileysTest.FakeConnection
             )

    original = :sys.get_state(client).credentials
    assert :ok = Baileys.reset_session(client)

    assert_receive {:baileys, ^client, {:qr, %Baileys.QR{payload: "fresh-qr"}}}
    refute :sys.get_state(client).credentials == original
    assert Baileys.status(client) == :awaiting_pairing

    assert :ok = Baileys.disconnect(client)
    GenServer.stop(client)
  end

  test "reset_session exposes store failures and leaves the client usable" do
    assert {:ok, server} =
             Baileys.start_link(BaileysTest.Handler, self(),
               connect: false,
               store: {BaileysTest.ResetFailureStore, []}
             )

    client = :sys.get_state(server).client
    original = :sys.get_state(client).credentials

    assert {:error, {:store, :read_only}} =
             Baileys.reset_session(server, reconnect: false)

    assert :sys.get_state(client).credentials == original
    assert Baileys.status(server) == :disconnected
    assert Process.alive?(server)
  end
end
