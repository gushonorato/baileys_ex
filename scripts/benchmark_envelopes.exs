alias Baileys.{Message, MessageKey, MessagingHistorySet}
alias BaileysExo.Proto.Message, as: ProtoMessage

iterations = String.to_integer(System.get_env("BENCH_ITERATIONS") || "1000")

for size <- [1_024, 64 * 1_024, 1024 * 1_024] do
  payload = :binary.copy(<<42>>, size)

  proto = %ProtoMessage{
    documentMessage: %ProtoMessage.DocumentMessage{
      fileName: "synthetic.bin",
      jpegThumbnail: payload
    }
  }

  raw = Protobuf.encode(proto)

  message = %Message{
    key: %MessageKey{
      remote_jid: "synthetic@s.whatsapp.net",
      from_me: false,
      id: "fixture",
      addressing_mode: :pn
    },
    content: proto,
    raw_content: raw,
    raw_payloads: [raw]
  }

  history = %MessagingHistorySet{messages: [message]}

  {microseconds, _} =
    :timer.tc(fn ->
      Enum.each(1..iterations, fn _ ->
        encoded = Protobuf.encode(proto)
        ^proto = ProtoMessage.decode(encoded)
      end)
    end)

  IO.puts(
    "bytes=#{size} iterations=#{iterations} total_us=#{microseconds} " <>
      "avg_us=#{div(microseconds, iterations)} retained_words=#{:erts_debug.flat_size({message, history})}"
  )
end
