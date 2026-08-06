defmodule Baileys.Server do
  @moduledoc false

  use GenServer

  alias Baileys.Client
  alias Baileys.Event
  alias Baileys.Store

  @gen_server_options [:name, :timeout, :debug, :spawn_opt, :hibernate_after]
  @client_options [:session, :store, :sessions_path, :request_timeout]

  def start_link(module, init_arg, options) do
    with :ok <- validate_store(options) do
      # Initialize without a link so adapter startup failures are returned to
      # the caller, then establish the usual start_link relationship.
      case GenServer.start(
             __MODULE__,
             {module, init_arg, options},
             Keyword.take(options, @gen_server_options)
           ) do
        {:ok, server} = started ->
          Process.link(server)
          started

        other ->
          other
      end
    end
  end

  @impl true
  def init({module, init_arg, options}) do
    with {:ok, callback_state} <- normalize_init(module.init(init_arg)),
         {:ok, client} <-
           Client.start(
             options
             |> Keyword.take(@client_options)
             |> Keyword.put(:owner, self())
           ) do
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
  defp run_command(client, {:reset_session, options}), do: Client.reset_session(client, options)

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

  defp validate_store(options) do
    cond do
      Keyword.has_key?(options, :store) and
          not Store.valid_config?(Keyword.fetch!(options, :store)) ->
        {:error, :invalid_store}

      Keyword.has_key?(options, :store) ->
        :ok

      Keyword.has_key?(options, :sessions_path) ->
        validate_sessions_path(Keyword.fetch!(options, :sessions_path))

      true ->
        {:error, :store_required}
    end
  end

  defp validate_sessions_path(path) when is_binary(path) do
    if Path.type(path) == :absolute,
      do: :ok,
      else: {:error, :sessions_path_must_be_absolute}
  end

  defp validate_sessions_path(_path), do: {:error, :invalid_sessions_path}
end
