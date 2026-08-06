defmodule Baileys.Store.MemoryTest do
  use ExUnit.Case, async: true

  alias Baileys.Store.Memory

  test "stores multiple sessions and deletes idempotently" do
    assert {:ok, memory} = Memory.init([])

    assert :not_found = Memory.fetch(memory, "one")
    assert :ok = Memory.put(memory, "one", "payload-one")
    assert :ok = Memory.put(memory, "two", "payload-two")
    assert {:ok, "payload-one"} = Memory.fetch(memory, "one")
    assert {:ok, "payload-two"} = Memory.fetch(memory, "two")
    assert :ok = Memory.delete(memory, "one")
    assert :ok = Memory.delete(memory, "one")
    assert :not_found = Memory.fetch(memory, "one")

    Agent.stop(memory)
  end

  test "each initialization is isolated" do
    assert {:ok, first} = Memory.init([])
    assert {:ok, second} = Memory.init([])
    assert :ok = Memory.put(first, "same", "first")
    assert :not_found = Memory.fetch(second, "same")

    Agent.stop(first)
    Agent.stop(second)
  end

  test "storage terminates with the process that initialized it" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, memory} = Memory.init([])
        send(parent, {:memory, memory})
        Process.sleep(:infinity)
      end)

    assert_receive {:memory, memory}
    monitor = Process.monitor(memory)
    Process.exit(owner, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^memory, :shutdown}
  end
end
