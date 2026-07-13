defmodule BaileysExo.Messages.ReceiverTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.Node
  alias BaileysExo.Messages.Receiver
  alias BaileysExo.Proto.Message

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

  test "exposes the phone JID for a LID-addressed direct message", %{credentials: credentials} do
    node = %Node{
      tag: "message",
      attrs: %{
        "id" => "incoming-lid-1",
        "from" => "987654321@lid",
        "sender_pn" => "5521999999999@s.whatsapp.net",
        "addressing_mode" => "lid",
        "t" => "1"
      }
    }

    assert {:ok, context} = Receiver.context(node, credentials)
    assert context.chat_jid == "5521999999999@s.whatsapp.net"
    assert context.sender_jid == "5521999999999@s.whatsapp.net"
    assert context.signal_jid == "987654321@lid"
    assert context.receipt_attrs == %{"id" => "incoming-lid-1", "to" => "987654321@lid"}
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

  test "extracts root and batched receipt ids in wire order" do
    receipt = %Node{
      tag: "receipt",
      attrs: %{"id" => "message-1"},
      content: [
        %Node{
          tag: "list",
          content: [
            %Node{tag: "item", attrs: %{"id" => "message-2"}},
            %Node{tag: "item", attrs: %{"id" => "message-3"}},
            %Node{tag: "item"}
          ]
        }
      ]
    }

    assert Receiver.receipt_ids(receipt) == ["message-1", "message-2", "message-3"]
  end

  test "maps receipt types without inventing delivery statuses" do
    assert Receiver.receipt_status(nil) == :delivered
    assert Receiver.receipt_status("sender") == :sent
    assert Receiver.receipt_status("read") == :read
    assert Receiver.receipt_status("read-self") == :read
    assert Receiver.receipt_status("played") == :played

    for type <- ["retry", "inactive", "hist_sync", "peer_msg", "future-type"] do
      assert Receiver.receipt_status(type) == :ignore
    end
  end

  test "uses a valid receipt timestamp" do
    receipt = %Node{tag: "receipt", attrs: %{"t" => "1700000000"}}
    fallback = fn -> ~U[2000-01-01 00:00:00Z] end

    assert Receiver.receipt_timestamp(receipt, fallback) == ~U[2023-11-14 22:13:20Z]
  end

  test "uses an injected clock for missing or malformed receipt timestamps" do
    fallback = fn -> ~U[2000-01-01 00:00:00Z] end

    assert Receiver.receipt_timestamp(%Node{tag: "receipt"}, fallback) == fallback.()

    assert Receiver.receipt_timestamp(
             %Node{tag: "receipt", attrs: %{"t" => "not-a-timestamp"}},
             fallback
           ) == fallback.()
  end

  test "builds a generic ack without a local message sender", %{credentials: credentials} do
    notification = %Node{
      tag: "notification",
      attrs: %{
        "id" => "notification-1",
        "from" => "s.whatsapp.net",
        "participant" => "5521888888888@s.whatsapp.net",
        "recipient" => "5511000000000@s.whatsapp.net",
        "type" => "devices"
      }
    }

    assert Receiver.ack(notification, credentials) == %Node{
             tag: "ack",
             attrs: %{
               "class" => "notification",
               "id" => "notification-1",
               "participant" => "5521888888888@s.whatsapp.net",
               "recipient" => "5511000000000@s.whatsapp.net",
               "to" => "s.whatsapp.net",
               "type" => "devices"
             }
           }
  end

  test "extracts text from nested future-proof message wrappers" do
    text = %Message{extendedTextMessage: %Message.ExtendedTextMessage{text: "recebida"}}

    message = %Message{
      ephemeralMessage: %Message.FutureProofMessage{
        message: %Message{
          editedMessage: %Message.FutureProofMessage{message: text}
        }
      }
    }

    encoded = Protobuf.encode(message)
    assert {:ok, "recebida"} = encoded |> Message.decode() |> Receiver.extract_text()
  end

  test "requests pending notifications after an offline preview" do
    preview = %Node{tag: "ib", content: [%Node{tag: "offline_preview"}]}

    assert {:ok, request} = Receiver.offline_batch_request(preview)

    assert request == %Node{
             tag: "ib",
             attrs: %{},
             content: [%Node{tag: "offline_batch", attrs: %{"count" => "100"}}]
           }
  end
end
