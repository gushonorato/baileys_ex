defmodule Baileys.StoreTest.FakeAdapter do
  @behaviour Baileys.Store.Adapter

  @impl true
  def init(options) do
    case Keyword.get(options, :init_result, :ok) do
      :ok -> {:ok, options}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def fetch(options, session) do
    send(Keyword.fetch!(options, :owner), {:fetch, session})
    Keyword.get(options, :fetch_result, :not_found)
  end

  @impl true
  def put(options, session, payload) do
    send(Keyword.fetch!(options, :owner), {:put, session, payload})
    Keyword.get(options, :put_result, :ok)
  end

  @impl true
  def delete(options, session) do
    send(Keyword.fetch!(options, :owner), {:delete, session})
    Keyword.get(options, :delete_result, :ok)
  end
end

defmodule Baileys.StoreTest do
  use ExUnit.Case, async: true

  alias Baileys.Auth.Credentials
  alias Baileys.Store
  alias Baileys.Store.JSONCodec
  alias Baileys.StoreTest.FakeAdapter

  test "opens an existing versioned payload" do
    credentials = Credentials.new()
    {:ok, payload} = JSONCodec.encode(credentials)

    assert {:ok, ^credentials, %Store{} = store} =
             open(fetch_result: {:ok, payload})

    assert_receive {:fetch, "primary"}
    assert :ok = Store.save(store, credentials)
    assert_receive {:put, "primary", ^payload}
  end

  test "creates and persists credentials when the session does not exist" do
    assert {:ok, %Credentials{} = credentials, %Store{}} = open([])
    assert_receive {:fetch, "primary"}
    assert_receive {:put, "primary", payload}
    assert {:ok, ^credentials} = JSONCodec.decode(payload)
  end

  test "rejects invalid and oversized payloads in the facade" do
    assert {:error, {:store, :invalid_credentials}} =
             open(fetch_result: {:ok, "not-json"})

    oversized = :binary.copy(<<0>>, 10 * 1024 * 1024 + 1)

    assert {:error, {:store, :session_too_large}} =
             open(fetch_result: {:ok, oversized})
  end

  test "reset deletes, creates and persists fresh credentials" do
    original = Credentials.new()
    {:ok, payload} = JSONCodec.encode(original)
    assert {:ok, ^original, store} = open(fetch_result: {:ok, payload})

    assert {:ok, %Credentials{} = reset} = Store.reset(store)
    refute reset == original
    assert_receive {:delete, "primary"}
    assert_receive {:put, "primary", reset_payload}
    assert {:ok, ^reset} = JSONCodec.decode(reset_payload)
  end

  test "normalizes adapter initialization, fetch, put and delete errors" do
    assert {:error, {:store, :init_failed}} =
             open(init_result: {:error, :init_failed})

    assert {:error, {:store, :fetch_failed}} =
             open(fetch_result: {:error, :fetch_failed})

    assert {:error, {:store, :put_failed}} =
             open(put_result: {:error, :put_failed})

    credentials = Credentials.new()
    {:ok, payload} = JSONCodec.encode(credentials)

    assert {:ok, ^credentials, store} =
             open(fetch_result: {:ok, payload}, delete_result: {:error, :delete_failed})

    assert {:error, {:store, :delete_failed}} = Store.reset(store)
  end

  test "rejects malformed adapter configurations" do
    assert {:error, :invalid_store} = Store.open(FakeAdapter, "primary")
    assert {:error, :invalid_store} = Store.open({String, []}, "primary")
    assert {:error, :invalid_store} = Store.open({FakeAdapter, [:invalid]}, "primary")
  end

  defp open(options) do
    Store.open({FakeAdapter, Keyword.put(options, :owner, self())}, "primary")
  end
end
