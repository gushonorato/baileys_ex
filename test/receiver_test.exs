defmodule BaileysExo.Messages.ReceiverTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.Node
  alias BaileysExo.Messages.Receiver

  setup do
    credentials = %Credentials{
      me: %{
        id: "5511000000000:2@s.whatsapp.net",
        lid: "123456789:2@lid"
      }
    }

    %{credentials: credentials}
  end

  test "normalizes an incoming direct message", %{credentials: credentials} do
    node = %Node{
      tag: "message",
      attrs: %{
        "id" => "incoming-1",
        "from" => "5521999999999@s.whatsapp.net",
        "sender_lid" => "987654321@lid",
        "t" => "1"
      }
    }

    assert {:ok, context} = Receiver.context(node, credentials)
    assert context.chat_jid == "5521999999999@s.whatsapp.net"
    assert context.sender_jid == "5521999999999@s.whatsapp.net"
    assert context.signal_jid == "987654321@lid"
    refute context.from_me
    assert context.receipt_attrs == %{"id" => "incoming-1", "to" => node.attrs["from"]}
  end

  test "uses the recipient as chat for a message synchronized from another device", %{
    credentials: credentials
  } do
    node = %Node{
      tag: "message",
      attrs: %{
        "id" => "outgoing-1",
        "from" => "5511000000000:7@s.whatsapp.net",
        "recipient" => "5521999999999@s.whatsapp.net",
        "t" => "2"
      }
    }

    assert {:ok, context} = Receiver.context(node, credentials)
    assert context.chat_jid == "5521999999999@s.whatsapp.net"
    assert context.from_me

    assert context.receipt_attrs == %{
             "id" => "outgoing-1",
             "recipient" => "5521999999999@s.whatsapp.net",
             "to" => "5511000000000:7@s.whatsapp.net",
             "type" => "sender"
           }
  end

  test "builds a message nack with routing attributes", %{credentials: credentials} do
    node = %Node{
      tag: "message",
      attrs: %{
        "id" => "failed-1",
        "from" => "5521999999999@s.whatsapp.net",
        "participant" => "5521888888888@s.whatsapp.net",
        "recipient" => "5511000000000@s.whatsapp.net",
        "type" => "text"
      }
    }

    assert Receiver.failure_ack(node, credentials) == %Node{
             tag: "ack",
             attrs: %{
               "class" => "message",
               "error" => "500",
               "from" => "5511000000000:2@s.whatsapp.net",
               "id" => "failed-1",
               "participant" => "5521888888888@s.whatsapp.net",
               "recipient" => "5511000000000@s.whatsapp.net",
               "to" => "5521999999999@s.whatsapp.net",
               "type" => "text"
             }
           }
  end

  test "builds a successful ack for a message without encrypted content", %{
    credentials: credentials
  } do
    node = %Node{
      tag: "message",
      attrs: %{
        "id" => "sync-1",
        "from" => "5521999999999@s.whatsapp.net",
        "recipient" => "5511000000000@s.whatsapp.net",
        "type" => "text"
      }
    }

    assert Receiver.ack(node, credentials) == %Node{
             tag: "ack",
             attrs: %{
               "class" => "message",
               "from" => "5511000000000:2@s.whatsapp.net",
               "id" => "sync-1",
               "recipient" => "5511000000000@s.whatsapp.net",
               "to" => "5521999999999@s.whatsapp.net",
               "type" => "text"
             }
           }
  end
end
