defmodule BaileysExo.ConnectionProcessTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.Node
  alias BaileysExo.Client
  alias BaileysExo.ConnectionProcess
  alias BaileysExo.{Crypto, Protocol.Pairing}

  setup do
    test_pid = self()

    state = %{
      owner: test_pid,
      credentials: %Credentials{me: %{id: "5511000000000:2@s.whatsapp.net"}},
      now: fn -> ~U[2000-01-01 00:00:00Z] end,
      node_sender: fn node ->
        send(test_pid, {:sent_node, node})
        :ok
      end
    }

    %{state: state}
  end

  test "emits one timestamped status per batched receipt id and acknowledges once", %{
    state: state
  } do
    receipt = %Node{
      tag: "receipt",
      attrs: %{
        "id" => "message-1",
        "from" => "5521999999999@s.whatsapp.net",
        "t" => "1700000000",
        "type" => "read-self"
      },
      content: [
        %Node{
          tag: "list",
          content: [%Node{tag: "item", attrs: %{"id" => "message-2"}}]
        }
      ]
    }

    assert {:ok, ^state} = ConnectionProcess.dispatch(receipt, state)

    for id <- ["message-1", "message-2"] do
      assert_receive {:connection_event,
                      {:message_status, ^id, "5521999999999@s.whatsapp.net", :read,
                       ~U[2023-11-14 22:13:20Z], nil}}
    end

    assert_receive {:sent_node,
                    %Node{
                      tag: "ack",
                      attrs: %{
                        "class" => "receipt",
                        "id" => "message-1",
                        "to" => "5521999999999@s.whatsapp.net",
                        "type" => "read-self"
                      }
                    }}

    refute_receive {:sent_node, %Node{tag: "ack"}}
  end

  test "keeps successful message acknowledgements silent", %{state: state} do
    ack = %Node{
      tag: "ack",
      attrs: %{
        "class" => "message",
        "id" => "message-1",
        "from" => "s.whatsapp.net"
      }
    }

    assert {:ok, ^state} = ConnectionProcess.dispatch(ack, state)
    refute_receive {:connection_event, {:message_status, _, _, _, _, _}}
  end

  test "emits failed message acknowledgements with server attributes", %{state: state} do
    ack = %Node{
      tag: "ack",
      attrs: %{
        "class" => "message",
        "id" => "message-1",
        "from" => "s.whatsapp.net",
        "error" => "403"
      }
    }

    assert {:ok, ^state} = ConnectionProcess.dispatch(ack, state)

    assert_receive {:connection_event,
                    {:message_status, "message-1", "s.whatsapp.net", :failed,
                     ~U[2000-01-01 00:00:00Z], error}}

    assert error == ack.attrs
  end

  test "acknowledges ignored and malformed receipts", %{state: state} do
    receipt = %Node{
      tag: "receipt",
      attrs: %{"from" => "s.whatsapp.net", "type" => "inactive", "t" => "invalid"}
    }

    assert {:ok, ^state} = ConnectionProcess.dispatch(receipt, state)

    refute_receive {:connection_event, {:message_status, _, _, _, _, _}}
    assert_receive {:sent_node, %Node{tag: "ack", attrs: attrs}}
    assert attrs == %{"class" => "receipt", "to" => "s.whatsapp.net", "type" => "inactive"}
  end

  test "attempts the receipt ack when status projection raises", %{state: state} do
    receipt = %Node{
      tag: "receipt",
      attrs: %{"id" => "message-1", "from" => "s.whatsapp.net", "t" => "invalid"}
    }

    state = %{state | now: fn -> raise "clock unavailable" end}

    assert {:ok, ^state} = ConnectionProcess.dispatch(receipt, state)
    assert_receive {:connection_event, {:error, {:receipt_projection_failed, %RuntimeError{}}}}
    assert_receive {:sent_node, %Node{tag: "ack"}}
  end

  test "projects the stanza timestamp into the public status" do
    at = ~U[2023-11-14 22:13:20Z]
    state = %{subscribers: %{self() => make_ref()}}

    assert {:noreply, ^state} =
             Client.handle_info(
               {:connection_event,
                {:message_status, "message-1", "5521999999999@s.whatsapp.net", :delivered, at,
                 nil}},
               state
             )

    client = self()

    assert_receive {:baileys, ^client,
                    {:message_status,
                     %Baileys.MessageStatus{
                       id: "message-1",
                       to: "5521999999999@s.whatsapp.net",
                       status: :delivered,
                       at: ^at,
                       error: nil
                     }}}
  end

  test "acknowledges an unsupported notification without a public event", %{state: state} do
    notification = %Node{
      tag: "notification",
      attrs: %{
        "id" => "notification-1",
        "from" => "s.whatsapp.net",
        "type" => "devices"
      }
    }

    assert {:ok, ^state} = ConnectionProcess.dispatch(notification, state)

    assert_receive {:sent_node,
                    %Node{
                      tag: "ack",
                      attrs: %{
                        "class" => "notification",
                        "id" => "notification-1",
                        "to" => "s.whatsapp.net",
                        "type" => "devices"
                      }
                    }}

    refute_receive {:connection_event, _event}
    refute_receive {:sent_node, %Node{tag: "ack"}}
  end

  test "finishes pairing-code registration and acknowledges its notification once", %{
    state: state
  } do
    credentials = Credentials.new()

    assert {:ok, code, _request, credentials} =
             Pairing.request_code(credentials, "+55 11 99999-9999", "ABCD1234")

    primary_ephemeral = Crypto.generate_x25519_key_pair()
    primary_identity = Crypto.generate_x25519_key_pair()
    salt = :binary.copy(<<1>>, 32)
    iv = :binary.copy(<<2>>, 16)
    key = Crypto.pbkdf2_sha256(code, salt, 131_072, 32)
    wrapped_primary = salt <> iv <> Crypto.aes_ctr(primary_ephemeral.public, key, iv)

    notification = %Node{
      tag: "notification",
      attrs: %{
        "id" => "pairing-1",
        "from" => "s.whatsapp.net",
        "type" => "link_code_companion_reg"
      },
      content: [
        %Node{
          tag: "link_code_companion_reg",
          content: [
            %Node{tag: "link_code_pairing_ref", content: "pairing-reference"},
            %Node{tag: "primary_identity_pub", content: primary_identity.public},
            %Node{
              tag: "link_code_pairing_wrapped_primary_ephemeral_pub",
              content: wrapped_primary
            }
          ]
        }
      ]
    }

    state =
      state
      |> Map.put(:credentials, credentials)
      |> Map.put(:pending_queries, %{})
      |> Map.put(:session_path, nil)

    assert {:ok, updated_state} = ConnectionProcess.dispatch(notification, state)
    assert map_size(updated_state.pending_queries) == 1

    assert_receive {:sent_node,
                    %Node{
                      tag: "iq",
                      content: [
                        %Node{
                          tag: "link_code_companion_reg",
                          attrs: %{"stage" => "companion_finish"}
                        }
                      ]
                    }}

    assert_receive {:connection_event, {:credentials, %Credentials{adv_secret_key: adv_secret}}}
    assert is_binary(adv_secret) and byte_size(adv_secret) == 32

    assert_receive {:sent_node,
                    %Node{
                      tag: "ack",
                      attrs: %{
                        "class" => "notification",
                        "id" => "pairing-1",
                        "to" => "s.whatsapp.net",
                        "type" => "link_code_companion_reg"
                      }
                    }}

    refute_receive {:sent_node, %Node{tag: "ack"}}
  end

  test "acknowledges call stanzas without exposing them", %{state: state} do
    call = %Node{
      tag: "call",
      attrs: %{"id" => "call-1", "from" => "5521999999999@s.whatsapp.net"}
    }

    assert {:ok, ^state} = ConnectionProcess.dispatch(call, state)

    assert_receive {:sent_node,
                    %Node{
                      tag: "ack",
                      attrs: %{
                        "class" => "call",
                        "id" => "call-1",
                        "to" => "5521999999999@s.whatsapp.net"
                      }
                    }}

    refute_receive {:connection_event, _event}
  end

  test "attempts acknowledgements for malformed notification and call stanzas", %{state: state} do
    malformed_notification = %Node{
      tag: "notification",
      attrs: %{"from" => "s.whatsapp.net"},
      content: [%Node{tag: "link_code_companion_reg"}]
    }

    assert {:error, :pairing_code_not_requested} =
             ConnectionProcess.dispatch(malformed_notification, state)

    assert_receive {:sent_node,
                    %Node{
                      tag: "ack",
                      attrs: %{"class" => "notification", "to" => "s.whatsapp.net"}
                    }}

    malformed_call = %Node{tag: "call", attrs: %{"from" => "s.whatsapp.net"}}
    assert {:ok, ^state} = ConnectionProcess.dispatch(malformed_call, state)

    assert_receive {:sent_node,
                    %Node{tag: "ack", attrs: %{"class" => "call", "to" => "s.whatsapp.net"}}}
  end
end
