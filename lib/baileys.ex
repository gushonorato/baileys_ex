defmodule Baileys do
  @moduledoc """
  OTP-native WhatsApp linked-device client and callback behaviour.

  A callback module starts with the same shape as a `GenServer`:

      Baileys.start_link(MyHandler, init_arg,
        name: MyHandler,
        session: "primary",
        store: {Baileys.Store.File, root: "/var/lib/my_app/baileys_sessions"}
      )

  Events are delivered to `c:handle_event/2` as `%Baileys.Event{}` values.
  """

  alias Baileys.Server

  @type callback_state :: term()
  @type event :: Baileys.Event.t()

  @callback init(init_arg :: term()) ::
              {:ok, callback_state()}
              | {:stop, reason :: term()}
              | :ignore

  @callback handle_event(event(), callback_state()) ::
              {:noreply, callback_state()}
              | {:stop, reason :: term(), callback_state()}

  @callback terminate(reason :: term(), callback_state()) :: term()
  @optional_callbacks terminate: 2

  defmacro __using__(_options) do
    quote location: :keep do
      @behaviour Baileys

      def child_spec(argument) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [argument]},
          type: :worker,
          restart: :permanent
        }
      end

      defoverridable child_spec: 1
    end
  end

  @doc """
  Starts a callback module using `GenServer.start_link/3`-style arguments.

  `:store` accepts an adapter/options tuple. Existing `:sessions_path`
  configurations remain supported as shorthand for `Baileys.Store.File`.
  """
  @spec start_link(module(), term(), keyword()) :: GenServer.on_start()
  def start_link(module, init_arg, options \\ []) when is_atom(module) and is_list(options) do
    Server.start_link(module, init_arg, options)
  end

  def connect(client), do: command(client, :connect, 30_000)
  def disconnect(client), do: command(client, :disconnect, 30_000)
  def logout(client), do: command(client, :logout, 30_000)

  @doc """
  Replaces the configured session with fresh credentials.

  Any current connection is stopped before the store is changed. By default a
  new connection is started immediately, allowing the client to emit a fresh
  QR code. Pass `reconnect: false` to leave the client disconnected.

  Store and reconnect failures are returned to the caller.
  """
  @spec reset_session(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def reset_session(client, options \\ []) do
    command(client, {:reset_session, options}, 30_000)
  end

  def request_pairing_code(client, phone, options \\ []) do
    command(client, {:pairing_code, phone, options}, 30_000)
  end

  def send_text(client, recipient, text, options \\ []) do
    command(client, {:send_text, recipient, text, options}, 60_000)
  end

  def status(client), do: command(client, :status, 5_000)

  def subscribe(client, subscriber \\ self()),
    do: command(client, {:subscribe, subscriber}, 5_000)

  def unsubscribe(client, subscriber \\ self()),
    do: command(client, {:unsubscribe, subscriber}, 5_000)

  @doc "Normalizes a phone number or direct-user JID."
  def jid(value) when is_binary(value) do
    cond do
      String.contains?(value, "@") and valid_jid?(value) -> {:ok, value}
      String.contains?(value, "@") -> {:error, :invalid_jid}
      true -> phone_jid(value)
    end
  end

  defp command(client, command, timeout) do
    GenServer.call(client, {:baileys_command, command}, timeout)
  catch
    :exit, _reason -> {:error, :not_connected}
  end

  defp phone_jid(phone) do
    digits = String.replace(phone, ~r/\D/, "")

    if String.length(digits) in 8..15 do
      {:ok, digits <> "@s.whatsapp.net"}
    else
      {:error, :invalid_phone}
    end
  end

  defp valid_jid?(jid) do
    case String.split(jid, "@", parts: 2) do
      [user, "s.whatsapp.net"] ->
        user =~ ~r/^\d{8,15}$/

      [user, server] when server in ["lid", "hosted", "hosted.lid"] ->
        user =~ ~r/^[a-zA-Z0-9._:-]+$/

      _ ->
        false
    end
  end
end

defmodule Baileys.Event do
  @moduledoc "Event delivered to a `Baileys` callback module."

  @type t :: %__MODULE__{client: pid(), type: atom(), data: term()}

  @enforce_keys [:client, :type, :data]
  defstruct [:client, :type, :data]
end
