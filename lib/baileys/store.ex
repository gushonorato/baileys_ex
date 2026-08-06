defmodule Baileys.Store do
  @moduledoc false

  alias Baileys.Auth.Credentials
  alias Baileys.Store.JSONCodec

  @max_payload_bytes 10 * 1024 * 1024
  @required_callbacks [init: 1, fetch: 2, put: 3, delete: 2]

  @opaque t :: %__MODULE__{
            adapter: module(),
            state: term(),
            session: String.t()
          }

  @enforce_keys [:adapter, :state, :session]
  defstruct [:adapter, :state, :session]

  @spec valid_config?(term()) :: boolean()
  def valid_config?({adapter, options}) when is_atom(adapter) and is_list(options) do
    Keyword.keyword?(options) and Code.ensure_loaded?(adapter) and
      Enum.all?(@required_callbacks, fn {name, arity} ->
        function_exported?(adapter, name, arity)
      end)
  end

  def valid_config?(_config), do: false

  @spec open({module(), keyword()}, String.t()) ::
          {:ok, Credentials.t(), t()} | {:error, :invalid_store | {:store, term()}}
  def open(config, session) do
    if valid_config?(config) do
      {adapter, options} = config

      case invoke(adapter, :init, [options]) do
        {:ok, adapter_state} ->
          store = %__MODULE__{adapter: adapter, state: adapter_state, session: session}
          load_or_create(store)

        {:error, reason} ->
          store_error(reason)

        other ->
          invalid_response(:init, other)
      end
    else
      {:error, :invalid_store}
    end
  end

  @spec save(t(), Credentials.t()) :: :ok | {:error, {:store, term()}}
  def save(%__MODULE__{} = store, %Credentials{} = credentials) do
    with {:ok, payload} <- JSONCodec.encode(credentials),
         :ok <- validate_size(payload),
         :ok <- put(store, payload) do
      :ok
    else
      {:error, {:store, _reason}} = error -> error
      {:error, reason} -> store_error(reason)
    end
  end

  @spec reset(t()) :: {:ok, Credentials.t()} | {:error, {:store, term()}}
  def reset(%__MODULE__{} = store) do
    credentials = Credentials.new()

    with :ok <- delete(store),
         :ok <- save(store, credentials) do
      {:ok, credentials}
    end
  end

  defp load_or_create(store) do
    case invoke(store.adapter, :fetch, [store.state, store.session]) do
      {:ok, payload} when is_binary(payload) -> decode_payload(payload, store)
      :not_found -> create(store)
      {:error, reason} -> store_error(reason)
      other -> invalid_response(:fetch, other)
    end
  end

  defp decode_payload(payload, store) do
    with :ok <- validate_size(payload) do
      case payload do
        <<131, _rest::binary>> ->
          with {:ok, credentials} <- JSONCodec.decode_legacy(payload),
               :ok <- save(store, credentials) do
            {:ok, credentials, store}
          else
            {:error, {:store, _reason}} = error -> error
            {:error, reason} -> store_error(reason)
          end

        _json ->
          case JSONCodec.decode(payload) do
            {:ok, credentials} -> {:ok, credentials, store}
            {:error, reason} -> store_error(reason)
          end
      end
    else
      {:error, reason} -> store_error(reason)
    end
  end

  defp create(store) do
    credentials = Credentials.new()

    case save(store, credentials) do
      :ok -> {:ok, credentials, store}
      {:error, {:store, _reason}} = error -> error
    end
  end

  defp put(store, payload) do
    case invoke(store.adapter, :put, [store.state, store.session, payload]) do
      :ok -> :ok
      {:error, reason} -> store_error(reason)
      other -> invalid_response(:put, other)
    end
  end

  defp delete(store) do
    case invoke(store.adapter, :delete, [store.state, store.session]) do
      :ok -> :ok
      {:error, reason} -> store_error(reason)
      other -> invalid_response(:delete, other)
    end
  end

  defp validate_size(payload) when byte_size(payload) <= @max_payload_bytes, do: :ok
  defp validate_size(_payload), do: {:error, :session_too_large}

  defp invoke(adapter, function, arguments) do
    apply(adapter, function, arguments)
  rescue
    error -> {:error, {:adapter_exception, error}}
  catch
    kind, reason -> {:error, {:adapter_exception, {kind, reason}}}
  end

  defp invalid_response(callback, response),
    do: store_error({:invalid_adapter_response, callback, response})

  defp store_error(reason), do: {:error, {:store, reason}}
end
