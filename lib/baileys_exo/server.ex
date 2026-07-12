defmodule BaileysExo.Server do
  @moduledoc false

  use GenServer

  alias Baileys.Event
  alias BaileysExo.Client

  @gen_server_options [:name, :timeout, :debug, :spawn_opt, :hibernate_after]
  @client_options [:session, :sessions_path, :request_timeout]

  def start_link(module, init_arg, options) do
    GenServer.start_link(
      __MODULE__,
      {module, init_arg, options},
      Keyword.take(options, @gen_server_options)
    )
  end

  @impl true
  def init({module, init_arg, options}) do
    with {:ok, callback_state} <- normalize_init(module.init(init_arg)),
         {:ok, client} <-
           Client.start_link(
             options
             |> Keyword.take(@client_options)
             |> Keyword.put(:owner, self())
           ) do
      Process.unlink(client)
      monitor = Process.monitor(client)

      state = %{
        module: module,
        callback_state: callback_state,
        client: client,
        client_monitor: monitor
      }

      if Keyword.get(options, :connect, true) do
        case Client.connect(client) do
          :ok -> {:ok, state}
          {:error, reason} -> {:stop, reason}
        end
      else
        {:ok, state}
      end
    else
      :ignore -> :ignore
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:baileys_command, command}, _from, state) do
    {:reply, run_command(state.client, command), state}
  end

  @impl true
  def handle_info({:baileys, client, {type, data}}, %{client: client} = state) do
    event = %Event{client: client, type: type, data: data}

    case state.module.handle_event(event, state.callback_state) do
      {:noreply, callback_state} ->
        {:noreply, %{state | callback_state: callback_state}}

      {:stop, reason, callback_state} ->
        {:stop, reason, %{state | callback_state: callback_state}}

      other ->
        {:stop, {:bad_handle_event_return, other}, state}
    end
  end

  def handle_info(
        {:DOWN, reference, :process, client, reason},
        %{client: client, client_monitor: reference} = state
      ) do
    {:stop, {:client_exit, reason}, state}
  end

  @impl true
  def terminate(reason, state) do
    if Process.alive?(state.client), do: Client.disconnect(state.client)

    if function_exported?(state.module, :terminate, 2) do
      state.module.terminate(reason, state.callback_state)
    end

    :ok
  end

  defp run_command(client, :connect), do: Client.connect(client)
  defp run_command(client, :disconnect), do: Client.disconnect(client)
  defp run_command(client, :logout), do: Client.logout(client)

  defp run_command(client, {:pairing_code, phone, options}),
    do: Client.request_pairing_code(client, phone, options)

  defp run_command(client, {:send_text, recipient, text, options}),
    do: Client.send_text(client, recipient, text, options)

  defp run_command(client, :status), do: Client.status(client)
  defp run_command(client, {:subscribe, subscriber}), do: Client.subscribe(client, subscriber)
  defp run_command(client, {:unsubscribe, subscriber}), do: Client.unsubscribe(client, subscriber)

  defp normalize_init({:ok, state}), do: {:ok, state}
  defp normalize_init({:stop, reason}), do: {:error, reason}
  defp normalize_init(:ignore), do: :ignore
  defp normalize_init(other), do: {:error, {:bad_init_return, other}}
end
