defmodule BaileysExo.Protocol.PairingTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.{Codec, NodeUtils}
  alias BaileysExo.Protocol.Pairing

  test "builds an eight-character pairing-code request" do
    credentials = Credentials.new()

    assert {:ok, "ABCD1234", node, updated} =
             Pairing.request_code(credentials, "+55 (11) 99999-9999", "ABCD1234")

    assert updated.pairing_code == "ABCD1234"
    assert updated.me.id == "5511999999999@s.whatsapp.net"
    assert node.attrs["xmlns"] == "md"

    registration = NodeUtils.child(node, "link_code_companion_reg")
    wrapped = NodeUtils.child(registration, "link_code_pairing_wrapped_companion_ephemeral_pub")
    assert byte_size(wrapped.content) == 80
    assert {:ok, decoded} = node |> Codec.encode() |> Codec.decode()
    assert decoded.tag == "iq"

    assert NodeUtils.child(decoded, "link_code_companion_reg").attrs["stage"] ==
             "companion_hello"
  end

  test "rejects invalid phone numbers and custom codes" do
    credentials = Credentials.new()

    assert {:error, :invalid_pairing_code} =
             Pairing.request_code(credentials, "+5511999999999", "short")

    assert {:error, :invalid_phone} =
             Pairing.request_code(credentials, "123", "ABCD1234")
  end
end
