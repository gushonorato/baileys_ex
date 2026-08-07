defmodule Baileys.Server do
  @moduledoc false

  use GenServer

  alias Baileys.Client
  alias Baileys.Event
  alias Baileys.Store

  require Logger

  @callback_call :"$baileys_callback_call"
  @callback_cast :"$baileys_callback_cast"

  defguardp is_callback_action(action)
            when action == :hibernate or action == :infinity or
                   (is_integer(action) and action >= 0) or
                   (is_tuple(action) and tuple_size(action) == 2 and
                      elem(action, 0) == :continue)

  @gen_server_options [:name, :timeout, :debug, :spawn_opt, :hibernate_after]
  @client_options [
    :session,
    :store,
    :sessions_path,
    :request_timeout,
    :browser,
    :sync_full_history
  ]

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
    with {:ok, callback_state, callback_action} <- normalize_init(module.init(init_arg)),
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
          :ok -> init_reply(state, callback_action)
          {:error, reason} -> {:stop, reason}
        end
      else
        init_reply(state, callback_action)
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

  def handle_call({@callback_call, request}, from, state) do
    state.module
    |> invoke_required(:handle_call, [request, from, state.callback_state])
    |> map_call_return(:handle_call, state)
  end

  @impl true
  def handle_cast({@callback_cast, request}, state) do
    state.module
    |> invoke_required(:handle_cast, [request, state.callback_state])
    |> map_noreply_return(:handle_cast, state)
  end

  @impl true
  def handle_info({:baileys, client, {type, data}}, %{client: client} = state) do
    event = %Event{client: client, type: type, data: data}

    state.module
    |> apply(:handle_event, [event, state.callback_state])
    |> map_noreply_return(:handle_event, state)
  end

  def handle_info({:baileys, _client, _event}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, reference, :process, client, reason},
        %{client: client, client_monitor: reference} = state
      ) do
    {:stop, {:client_exit, reason}, state}
  end

  def handle_info({:baileys_command, _command}, state), do: {:noreply, state}
  def handle_info({@callback_call, _request}, state), do: {:noreply, state}
  def handle_info({@callback_cast, _request}, state), do: {:noreply, state}

  def handle_info(message, state) do
    if function_exported?(state.module, :handle_info, 2) do
      state.module
      |> apply(:handle_info, [message, state.callback_state])
      |> map_noreply_return(:handle_info, state)
    else
      Logger.error(
        "#{inspect(state.module)} received unexpected message in handle_info/2: " <>
          inspect(message)
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_continue(continue_arg, state) do
    state.module
    |> invoke_required(:handle_continue, [continue_arg, state.callback_state])
    |> map_noreply_return(:handle_continue, state)
  end

  @impl true
  def code_change(old_vsn, state, extra) do
    if function_exported?(state.module, :code_change, 3) do
      case state.module.code_change(old_vsn, state.callback_state, extra) do
        {:ok, callback_state} -> {:ok, put_callback_state(state, callback_state)}
        {:error, _reason} = error -> error
        other -> {:error, {:bad_code_change_return, other}}
      end
    else
      {:ok, state}
    end
  end

  @impl true
  def format_status(%{state: %{module: module, callback_state: callback_state}} = status) do
    status = Map.put(status, :state, callback_state)

    if function_exported?(module, :format_status, 1) do
      module.format_status(status)
    else
      status
    end
  end

  def format_status(status), do: status

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

  defp map_call_return({:reply, reply, callback_state}, _callback, state) do
    {:reply, reply, put_callback_state(state, callback_state)}
  end

  defp map_call_return({:reply, reply, callback_state, action}, _callback, state)
       when is_callback_action(action) do
    {:reply, reply, put_callback_state(state, callback_state), action}
  end

  defp map_call_return({:noreply, callback_state}, _callback, state) do
    {:noreply, put_callback_state(state, callback_state)}
  end

  defp map_call_return({:noreply, callback_state, action}, _callback, state)
       when is_callback_action(action) do
    {:noreply, put_callback_state(state, callback_state), action}
  end

  defp map_call_return({:stop, reason, reply, callback_state}, _callback, state) do
    {:stop, reason, reply, put_callback_state(state, callback_state)}
  end

  defp map_call_return({:stop, reason, callback_state}, _callback, state) do
    {:stop, reason, put_callback_state(state, callback_state)}
  end

  defp map_call_return(other, callback, state) do
    {:stop, bad_return(callback, other), state}
  end

  defp map_noreply_return({:noreply, callback_state}, _callback, state) do
    {:noreply, put_callback_state(state, callback_state)}
  end

  defp map_noreply_return({:noreply, callback_state, action}, _callback, state)
       when is_callback_action(action) do
    {:noreply, put_callback_state(state, callback_state), action}
  end

  defp map_noreply_return({:stop, reason, callback_state}, _callback, state) do
    {:stop, reason, put_callback_state(state, callback_state)}
  end

  defp map_noreply_return(other, callback, state) do
    {:stop, bad_return(callback, other), state}
  end

  defp put_callback_state(state, callback_state),
    do: %{state | callback_state: callback_state}

  defp bad_return(:handle_call, return), do: {:bad_handle_call_return, return}
  defp bad_return(:handle_cast, return), do: {:bad_handle_cast_return, return}
  defp bad_return(:handle_info, return), do: {:bad_handle_info_return, return}
  defp bad_return(:handle_continue, return), do: {:bad_handle_continue_return, return}
  defp bad_return(:handle_event, return), do: {:bad_handle_event_return, return}

  defp invoke_required(module, callback, arguments) do
    if function_exported?(module, callback, length(arguments)) do
      apply(module, callback, arguments)
    else
      missing_callback!(module, callback, length(arguments))
    end
  end

  defp missing_callback!(module, callback, arity) do
    server =
      case Process.info(self(), :registered_name) do
        {:registered_name, []} -> self()
        {:registered_name, name} -> name
      end

    raise "attempted to invoke Baileys callback #{inspect(module)} in #{inspect(server)}, " <>
            "but no #{callback}/#{arity} callback was provided"
  end

  defp init_reply(state, nil), do: {:ok, state}
  defp init_reply(state, action), do: {:ok, state, action}

  defp normalize_init({:ok, state}), do: {:ok, state, nil}

  defp normalize_init({:ok, state, action} = return) do
    if is_callback_action(action),
      do: {:ok, state, action},
      else: {:error, {:bad_init_return, return}}
  end

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
