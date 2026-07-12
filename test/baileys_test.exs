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
