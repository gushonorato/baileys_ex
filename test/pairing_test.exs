defmodule Baileys.Protocol.PairingTest do
  use ExUnit.Case, async: true

  alias Baileys.Auth.Credentials
  alias Baileys.Binary.{Codec, Node, NodeUtils}
  alias Baileys.Protocol.Pairing

  test "builds an eight-character pairing-code request" do
    credentials = Credentials.new()

    assert {:ok, "ABCD1234", node, updated} =
             Pairing.request_code(credentials, "+55 (11) 99999-9999", "ABCD1234")

    assert updated.pairing_code == "ABCD1234"
    assert updated.me.id == "5511999999999@s.whatsapp.net"
    assert node.attrs["xmlns"] == "md"

    registration = NodeUtils.child(node, "link_code_companion_reg")
    wrapped = NodeUtils.child(registration, "link_code_pairing_wrapped_companion_ephemeral_pub")
    assert %Node{content: {:text, "1"}} = NodeUtils.child(registration, "companion_platform_id")

    assert %Node{content: {:text, "Chrome (Mac OS)"}} =
             NodeUtils.child(registration, "companion_platform_display")

    assert byte_size(wrapped.content) == 80
    assert {:ok, decoded} = node |> Codec.encode() |> Codec.decode()
    assert decoded.tag == "iq"

    assert NodeUtils.child(decoded, "link_code_companion_reg").attrs["stage"] ==
             "companion_hello"
  end

  test "builds QR data with the Chrome companion platform" do
    credentials = Credentials.new()
    payload = Pairing.qr_payload("reference", credentials)

    assert String.starts_with?(
             payload,
             "https://wa.me/settings/linked_devices#reference,#{Base.encode64(credentials.noise_key.public)},"
           )

    assert String.ends_with?(payload, ",1")
  end

  test "uses the Windows desktop identity for full-history pairing" do
    credentials = Credentials.new()
    options = [browser: :windows_desktop, sync_full_history: true]

    assert {:ok, "ABCD1234", node, _updated} =
             Pairing.request_code(
               credentials,
               "+55 (11) 99999-9999",
               "ABCD1234",
               options
             )

    registration = NodeUtils.child(node, "link_code_companion_reg")

    assert %Node{content: {:text, "8"}} =
             NodeUtils.child(registration, "companion_platform_id")

    assert %Node{content: {:text, "Desktop (Windows)"}} =
             NodeUtils.child(registration, "companion_platform_display")

    assert Pairing.qr_payload("reference", credentials, options) |> String.ends_with?(",8")
  end

  test "rejects invalid phone numbers and custom codes" do
    credentials = Credentials.new()

    assert {:error, :invalid_pairing_code} =
             Pairing.request_code(credentials, "+5511999999999", "short")

    assert {:error, :invalid_phone} =
             Pairing.request_code(credentials, "123", "ABCD1234")
  end
end
