defmodule Baileys.Messages.SenderTest do
  use ExUnit.Case, async: true

  alias Baileys.Auth.Credentials
  alias Baileys.Binary.{Node, NodeUtils}
  alias Baileys.Messages.Sender

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

  test "attaches a current privacy token using PN to LID mapping" do
    timestamp = System.system_time(:second)

    credentials = %Credentials{
      lid_mappings: %{"5511999999999@s.whatsapp.net" => "9000@lid"},
      privacy_tokens: %{"9000@lid" => %{token: <<9, 8, 7>>, timestamp: timestamp}}
    }

    stanza = %Node{tag: "message", content: [%Node{tag: "participants"}]}

    stanza =
      Sender.attach_privacy_token(stanza, "5511999999999@s.whatsapp.net", credentials)

    assert %Node{attrs: %{"t" => encoded_timestamp}, content: <<9, 8, 7>>} =
             NodeUtils.child(stanza, "tctoken")

    assert encoded_timestamp == Integer.to_string(timestamp)
  end
end
