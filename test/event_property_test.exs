defmodule Baileys.EventPropertyTest do
  use ExUnit.Case, async: true

  alias Baileys.Binary.{Codec, Node}
  alias Baileys.Proto.{Message, MessageContextInfo}

  test "synthetic protobuf messages round trip across varied binary payloads" do
    :rand.seed(:exsss, {17, 23, 41})

    for sequence <- 1..200 do
      bytes = random_bytes(rem(sequence * 17, 1024))

      message = %Message{
        conversation: Base.encode64(bytes),
        messageContextInfo: %MessageContextInfo{messageSecret: bytes}
      }

      assert message == message |> Protobuf.encode() |> Message.decode()
    end
  end

  test "binary node codec returns bounded errors for generated malformed frames" do
    :rand.seed(:exsss, {43, 47, 53})

    for size <- 0..256 do
      malformed = random_bytes(size)

      assert match?({:ok, %Node{}}, Codec.decode(malformed)) or
               match?({:error, _}, Codec.decode(malformed))
    end
  end

  defp random_bytes(0), do: <<>>
  defp random_bytes(size), do: for(_ <- 1..size, into: <<>>, do: <<:rand.uniform(256) - 1>>)
end
