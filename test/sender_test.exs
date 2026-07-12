defmodule BaileysExo.Messages.SenderTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Binary.NodeUtils
  alias BaileysExo.Messages.Sender

  test "direct message relay does not put phash on the outer stanza" do
    participant = {"5511999999999@s.whatsapp.net", :msg, <<1, 2, 3>>}

    stanza =
      Sender.relay_stanza(
        "3EB001",
        "5511999999999@s.whatsapp.net",
        [participant],
        nil
      )

    refute Map.has_key?(stanza.attrs, "phash")

    assert stanza.attrs == %{
             "id" => "3EB001",
             "to" => "5511999999999@s.whatsapp.net",
             "type" => "text"
           }

    assert %{} = NodeUtils.child(stanza, "participants")
  end
end
