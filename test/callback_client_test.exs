defmodule Baileys.CallbackClientTest.LegacyHandler do
  use Baileys

  @impl Baileys
  def init(owner), do: {:ok, %{owner: owner, events: 0}}

  @impl Baileys
  def handle_event(event, state) do
    send(state.owner, {:legacy_event, event, Baileys.status(event.client)})
    {:noreply, %{state | events: state.events + 1}}
  end
end

defmodule Baileys.CallbackClientTest.Handler do
  use Baileys

  @impl Baileys
  def init({owner, id}) do
    {:ok,
     %{
       owner: owner,
       id: id,
       qr: nil,
       value: nil,
       events: 0,
       continues: [],
       infos: []
     }}
  end

  def init({:continue, owner, id}) do
    case init({owner, id}) do
      {:ok, state} -> {:ok, state, {:continue, :load_state}}
    end
  end

  @impl Baileys
  def handle_event(%Baileys.Event{type: :qr, data: qr}, state) do
    send(state.owner, {:handled_event, state.id, :qr})
    {:noreply, %{state | qr: qr, events: state.events + 1}}
  end

  def handle_event(%Baileys.Event{type: :event_continue}, state) do
    {:noreply, %{state | events: state.events + 1}, {:continue, :after_event}}
  end

  def handle_event(%Baileys.Event{}, state) do
    {:noreply, %{state | events: state.events + 1}}
  end

  @impl Baileys
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:put, key, value}, _from, state) do
    state = Map.put(state, key, value)
    {:reply, :ok, state}
  end

  def handle_call({:reply_action, key, value, action}, _from, state) do
    {:reply, :ok, Map.put(state, key, value), action}
  end

  def handle_call({:noreply, key, value}, from, state) do
    GenServer.reply(from, :ok)
    {:noreply, Map.put(state, key, value)}
  end

  def handle_call({:noreply_action, key, value, action}, from, state) do
    GenServer.reply(from, :ok)
    {:noreply, Map.put(state, key, value), action}
  end

  def handle_call({:monitor, pid}, _from, state) do
    {:reply, Process.monitor(pid), state}
  end

  def handle_call({:stop_with_reply, reason, value}, _from, state) do
    {:stop, reason, :stopped, %{state | value: value}}
  end

  def handle_call({:stop_without_reply, reason, value}, _from, state) do
    {:stop, reason, %{state | value: value}}
  end

  def handle_call(:raise, _from, _state), do: raise("callback call failed")

  @impl Baileys
  def handle_cast({:put, key, value}, state) do
    {:noreply, Map.put(state, key, value)}
  end

  def handle_cast({:put_action, key, value, action}, state) do
    {:noreply, Map.put(state, key, value), action}
  end

  @impl Baileys
  def handle_info(:reconnect, state) do
    send(state.owner, {:handled_info, state.id, :reconnect})
    {:noreply, %{state | infos: [:reconnect | state.infos]}}
  end

  def handle_info(:timeout, state) do
    send(state.owner, {:handled_info, state.id, :timeout})
    {:noreply, %{state | infos: [:timeout | state.infos]}}
  end

  def handle_info({:DOWN, _reference, :process, pid, reason} = message, state) do
    send(state.owner, {:handled_info, state.id, message})
    {:noreply, %{state | infos: [{:DOWN, pid, reason} | state.infos]}}
  end

  def handle_info(:invalid_return, _state), do: :invalid

  @impl Baileys
  def handle_continue(continue, state) do
    send(state.owner, {:handled_continue, state.id, continue})
    {:noreply, %{state | continues: state.continues ++ [continue]}}
  end

  @impl Baileys
  def terminate(reason, state) do
    send(state.owner, {:callback_terminated, state.id, reason, state})
  end

  @impl Baileys
  def code_change(_old_vsn, state, {:put, key, value}) do
    {:ok, Map.put(state, key, value)}
  end

  @impl Baileys
  def format_status(%{state: state} = status) do
    %{status | state: Map.take(state, [:id, :qr, :value])}
  end
end

defmodule Baileys.CallbackClientTest.NoOptionalCallbacks do
  use Baileys

  @impl Baileys
  def init(owner), do: {:ok, %{owner: owner}}

  @impl Baileys
  def handle_event(_event, state), do: {:noreply, state}
end

defmodule Baileys.CallbackClientTest.MissingContinue do
  use Baileys

  @impl Baileys
  def init(owner), do: {:ok, %{owner: owner}}

  @impl Baileys
  def handle_event(_event, state), do: {:noreply, state}

  @impl Baileys
  def handle_call(:continue, _from, state) do
    {:reply, :ok, state, {:continue, :missing}}
  end
end

defmodule Baileys.CallbackClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Baileys.CallbackClientTest.Handler
  alias Baileys.CallbackClientTest.LegacyHandler
  alias Baileys.CallbackClientTest.MissingContinue
  alias Baileys.CallbackClientTest.NoOptionalCallbacks

  defp start_callback(module, init_arg) do
    Baileys.start_link(module, init_arg,
      connect: false,
      store: {Baileys.Store.Memory, []}
    )
  end

  defp start_handler(id \\ :handler) do
    start_callback(Handler, {self(), id})
  end

  defp client(server), do: :sys.get_state(server).client

  test "legacy callbacks still start, receive events, and call client commands synchronously" do
    assert {:ok, server} = start_callback(LegacyHandler, self())
    client = client(server)
    event = %Baileys.QR{payload: "legacy"}

    send(server, {:baileys, client, {:qr, event}})

    assert_receive {:legacy_event, %Baileys.Event{client: ^client, type: :qr, data: ^event},
                    :disconnected}

    assert Process.alive?(server)
  end

  test "an event updates callback state and a later call reads it" do
    assert {:ok, server} = start_handler()
    client = client(server)
    qr = %Baileys.QR{payload: "current"}

    send(server, {:baileys, client, {:qr, qr}})
    assert_receive {:handled_event, :handler, :qr}

    assert %{qr: ^qr, events: 1} = Baileys.call(server, :state)
  end

  test "call and cast delegate through explicit callback envelopes" do
    assert {:ok, server} = start_handler()

    assert :ok = Baileys.call(server, {:put, :value, 1})
    assert :ok = Baileys.cast(server, {:put, :value, 2})
    assert %{value: 2} = Baileys.call(server, :state)
  end

  test "ordinary messages delegate to handle_info" do
    assert {:ok, server} = start_handler()

    send(server, :reconnect)

    assert_receive {:handled_info, :handler, :reconnect}
    assert %{infos: [:reconnect]} = Baileys.call(server, :state)
  end

  test "handle_continue works from init, events, calls, and casts" do
    assert {:ok, server} = start_callback(Handler, {:continue, self(), :continued})
    assert_receive {:handled_continue, :continued, :load_state}
    private_state = Map.delete(:sys.get_state(server), :callback_state)

    client = client(server)
    send(server, {:baileys, client, {:event_continue, nil}})
    assert_receive {:handled_continue, :continued, :after_event}

    assert :ok = Baileys.call(server, {:reply_action, :value, 1, {:continue, :after_call}})
    assert_receive {:handled_continue, :continued, :after_call}

    assert :ok =
             Baileys.cast(
               server,
               {:put_action, :value, 2, {:continue, :after_cast}}
             )

    assert_receive {:handled_continue, :continued, :after_cast}

    assert %{continues: [:load_state, :after_event, :after_call, :after_cast], value: 2} =
             Baileys.call(server, :state)

    assert Map.delete(:sys.get_state(server), :callback_state) == private_state
  end

  test "valid reply and noreply forms preserve the private server state" do
    assert {:ok, server} = start_handler()
    before = :sys.get_state(server)

    assert :ok = Baileys.call(server, {:put, :value, :reply})
    assert :ok = Baileys.call(server, {:reply_action, :value, :hibernate, :hibernate})
    assert :ok = Baileys.call(server, {:noreply, :value, :noreply})

    assert :ok =
             Baileys.call(server, {:noreply_action, :value, :timeout, 0})

    assert_receive {:handled_info, :handler, :timeout}

    after_callbacks = :sys.get_state(server)

    assert Map.delete(after_callbacks, :callback_state) == Map.delete(before, :callback_state)
    assert after_callbacks.callback_state.value == :timeout
    assert after_callbacks.callback_state.infos == [:timeout]
  end

  test "stop with a reply stores the latest callback state for terminate" do
    assert {:ok, server} = start_handler(:stop_reply)
    Process.unlink(server)
    monitor = Process.monitor(server)

    assert :stopped = Baileys.call(server, {:stop_with_reply, :normal, :latest})

    assert_receive {:callback_terminated, :stop_reply, :normal, %{value: :latest}}
    assert_receive {:DOWN, ^monitor, :process, ^server, :normal}
  end

  test "stop without a reply stores the latest callback state for terminate" do
    assert {:ok, server} = start_handler(:stop_no_reply)
    Process.unlink(server)
    monitor = Process.monitor(server)
    parent = self()

    spawn(fn ->
      result = catch_exit(Baileys.call(server, {:stop_without_reply, :shutdown, :latest}))
      send(parent, {:call_exit, result})
    end)

    assert_receive {:callback_terminated, :stop_no_reply, :shutdown, %{value: :latest}}
    assert_receive {:DOWN, ^monitor, :process, ^server, :shutdown}
    assert_receive {:call_exit, {:shutdown, _call}}
  end

  test "code_change replaces only callback state" do
    assert {:ok, server} = start_handler()
    before = :sys.get_state(server)

    assert :ok = :sys.suspend(server)
    assert :ok = :sys.change_code(server, Baileys.Server, :old, {:put, :value, :upgraded})
    assert :ok = :sys.resume(server)

    after_change = :sys.get_state(server)

    assert Map.delete(after_change, :callback_state) == Map.delete(before, :callback_state)
    assert %{value: :upgraded} = Baileys.call(server, :state)
  end

  test "format_status receives and returns only the callback state" do
    assert {:ok, server} = start_handler()
    assert :ok = Baileys.call(server, {:put, :value, :visible})
    internal = :sys.get_state(server)

    formatted =
      Baileys.Server.format_status(%{
        state: internal,
        message: :status,
        reason: :normal
      })

    assert formatted.state == %{id: :handler, qr: nil, value: :visible}
    refute Map.has_key?(formatted.state, :client)
    refute Map.has_key?(formatted.state, :callback_state)
  end

  test "internal commands and events do not reach handle_info" do
    assert {:ok, server} = start_handler()
    client = client(server)

    assert :disconnected = Baileys.status(server)
    refute_receive {:handled_info, :handler, _message}

    send(server, {:baileys, client, {:qr, %Baileys.QR{payload: "reserved"}}})
    assert_receive {:handled_event, :handler, :qr}
    refute_receive {:handled_info, :handler, _message}
  end

  test "the monitored client DOWN keeps its reserved shutdown behavior" do
    assert {:ok, server} = start_handler(:client_down)
    Process.unlink(server)
    monitor = Process.monitor(server)
    client = client(server)

    Process.exit(client, :kill)

    assert_receive {:callback_terminated, :client_down, {:client_exit, :killed}, _state}
    assert_receive {:DOWN, ^monitor, :process, ^server, {:client_exit, :killed}}
    refute_receive {:handled_info, :client_down, {:DOWN, _, :process, ^client, :killed}}
  end

  test "an unrelated DOWN message reaches handle_info" do
    assert {:ok, server} = start_handler()
    unrelated = spawn(fn -> Process.sleep(:infinity) end)
    assert reference = Baileys.call(server, {:monitor, unrelated})

    Process.exit(unrelated, :shutdown)

    assert_receive {:handled_info, :handler, {:DOWN, ^reference, :process, ^unrelated, :shutdown}}
    assert Process.alive?(server)
  end

  test "invalid returns stop the server with a callback-specific reason" do
    assert {:ok, server} = start_handler(:invalid)
    Process.unlink(server)
    monitor = Process.monitor(server)

    send(server, :invalid_return)

    assert_receive {:callback_terminated, :invalid, {:bad_handle_info_return, :invalid}, _state}

    assert_receive {:DOWN, ^monitor, :process, ^server, {:bad_handle_info_return, :invalid}}
  end

  test "callback exceptions stop the server and run terminate with the latest state" do
    assert {:ok, server} = start_handler(:exception)
    assert :ok = Baileys.call(server, {:put, :value, :latest})
    Process.unlink(server)
    monitor = Process.monitor(server)
    parent = self()

    spawn(fn -> send(parent, {:call_exit, catch_exit(Baileys.call(server, :raise))}) end)

    assert_receive {:callback_terminated, :exception,
                    {%RuntimeError{message: "callback call failed"}, _stack}, %{value: :latest}}

    assert_receive {:DOWN, ^monitor, :process, ^server,
                    {%RuntimeError{message: "callback call failed"}, _stack}}

    assert_receive {:call_exit, {{%RuntimeError{message: "callback call failed"}, _stack}, _call}}
  end

  test "two callback clients keep completely isolated states" do
    assert {:ok, first} = start_handler(:first)
    assert {:ok, second} = start_handler(:second)

    assert :ok = Baileys.cast(first, {:put, :value, 1})
    assert :ok = Baileys.cast(second, {:put, :value, 2})

    assert %{id: :first, value: 1} = Baileys.call(first, :state)
    assert %{id: :second, value: 2} = Baileys.call(second, :state)
    refute client(first) == client(second)
  end

  test "a missing handle_call fails like a GenServer call" do
    assert {:ok, server} = start_callback(NoOptionalCallbacks, self())
    Process.unlink(server)
    monitor = Process.monitor(server)

    assert {{%RuntimeError{message: message}, _stack}, _call} =
             catch_exit(Baileys.call(server, :unsupported))

    assert message =~ "no handle_call/3 callback"
    assert_receive {:DOWN, ^monitor, :process, ^server, {%RuntimeError{}, _stack}}
  end

  test "a missing handle_cast fails like a GenServer cast" do
    assert {:ok, server} = start_callback(NoOptionalCallbacks, self())
    Process.unlink(server)
    monitor = Process.monitor(server)

    assert :ok = Baileys.cast(server, :unsupported)
    assert_receive {:DOWN, ^monitor, :process, ^server, {%RuntimeError{message: message}, _stack}}
    assert message =~ "no handle_cast/2 callback"
  end

  test "a missing handle_info logs and ignores an ordinary message" do
    assert {:ok, server} = start_callback(NoOptionalCallbacks, self())

    log =
      capture_log(fn ->
        send(server, :unexpected)
        assert :disconnected = Baileys.status(server)
      end)

    assert log =~ "unexpected message"
    assert Process.alive?(server)
  end

  test "a missing handle_continue fails when a callback requests continuation" do
    assert {:ok, server} = start_callback(MissingContinue, self())
    Process.unlink(server)
    monitor = Process.monitor(server)

    assert :ok = Baileys.call(server, :continue)

    assert_receive {:DOWN, ^monitor, :process, ^server, {%RuntimeError{message: message}, _stack}}
    assert message =~ "no handle_continue/2 callback"
  end
end
