defmodule BaileysExo.ProtobufTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Proto.HandshakeMessage

  test "round trips the minimal handshake protobuf" do
    message = %HandshakeMessage{
      clientHello: %HandshakeMessage.ClientHello{ephemeral: :binary.copy(<<1>>, 32)}
    }

    encoded = Protobuf.encode(message)
    assert HandshakeMessage.decode(encoded) == message
  end
end
