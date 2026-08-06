count = String.to_integer(System.get_env("SOAK_EVENTS") || "100000")
state = %{subscribers: %{self() => make_ref()}}
before = :erlang.memory(:total)

peak_mailbox =
  Enum.reduce(1..count, 0, fn sequence, maximum ->
    update = %{id: "synthetic-#{sequence}", img_url: :changed}

    {:noreply, ^state} =
      Baileys.Client.handle_info({:connection_event, {:contacts_update, [update]}}, state)

    {:message_queue_len, length} = Process.info(self(), :message_queue_len)
    max(maximum, length)
  end)

Enum.each(1..count, fn sequence ->
  receive do
    {:baileys, _client, {:contacts_update, [%Baileys.ContactUpdate{id: "synthetic-" <> id}]}} ->
      ^sequence = String.to_integer(id)
  after
    120_000 -> raise "soak timeout"
  end
end)

after_memory = :erlang.memory(:total)
IO.puts("events=#{count} peak_mailbox=#{peak_mailbox} memory_delta=#{after_memory - before}")
