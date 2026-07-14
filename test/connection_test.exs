defmodule BaileysExo.ConnectionProcessTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.{Node, NodeUtils}
  alias BaileysExo.Client
  alias BaileysExo.ConnectionProcess
  alias BaileysExo.Crypto.XEdDSA
  alias BaileysExo.Messages.Sender
  alias BaileysExo.Proto.Message
  alias BaileysExo.Signal.{SessionBuilder, SessionCipher}
  alias BaileysExo.{Crypto, Protocol.Pairing}

  setup do
    test_pid = self()

    state = %{
      owner: test_pid,
      credentials: %Credentials{me: %{id: "5511000000000:2@s.whatsapp.net"}},
      now: fn -> ~U[2000-01-01 00:00:00Z] end,
      diagnostic_sender: fn diagnostic -> send(test_pid, {:diagnostic, diagnostic}) end,
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

    assert_receive {:connection_event, {:messages_update, updates}}
    assert Enum.map(updates, & &1.key.id) == ["message-1", "message-2"]
    assert Enum.all?(updates, &(&1.update.status == :read))
    assert Enum.all?(updates, &(&1.update.timestamp == ~U[2023-11-14 22:13:20Z]))

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

    assert_receive {:connection_event, {:messages_update, [update]}}
    assert update.key.id == "message-1"
    assert update.update.status == :failed
    assert update.update.error == ack.attrs
  end

  test "emits per-user group receipt updates without a direct status", %{state: state} do
    receipt = %Node{
      tag: "receipt",
      attrs: %{
        "id" => "group-message-1",
        "from" => "fixture-group@g.us",
        "participant" => "remote-user:3@s.whatsapp.net",
        "t" => "1700000000",
        "type" => "played"
      },
      content: [
        %Node{
          tag: "list",
          content: [%Node{tag: "item", attrs: %{"id" => "group-message-2"}}]
        }
      ]
    }

    assert {:ok, ^state} = ConnectionProcess.dispatch(receipt, state)
    refute_receive {:connection_event, {:message_status, _, _, _, _, _}}

    assert_receive {:connection_event, {:message_receipt_update, updates}}
    assert Enum.map(updates, & &1.key.id) == ["group-message-1", "group-message-2"]

    assert Enum.all?(updates, fn update ->
             update.key.remote_jid == "fixture-group@g.us" and
               update.key.participant == "remote-user:3@s.whatsapp.net" and
               update.receipt.user_jid == "remote-user@s.whatsapp.net" and
               update.receipt.played_timestamp == ~U[2023-11-14 22:13:20Z]
           end)

    assert_receive {:sent_node, %Node{tag: "ack"}}
  end

  test "targets own-device receipts at the recipient conversation", %{state: state} do
    receipt = %Node{
      tag: "receipt",
      attrs: %{
        "id" => "incoming-message-1",
        "from" => "5511000000000:7@s.whatsapp.net",
        "recipient" => "5521999999999@s.whatsapp.net",
        "t" => "1700000000",
        "type" => "read-self"
      }
    }

    assert {:ok, ^state} = ConnectionProcess.dispatch(receipt, state)
    assert_receive {:connection_event, {:messages_update, [update]}}
    assert update.key.remote_jid == "5521999999999@s.whatsapp.net"
    refute update.key.from_me
    assert_receive {:sent_node, %Node{tag: "ack"}}
  end

  test "suppresses group user receipt updates without a participant", %{state: state} do
    receipt = %Node{
      tag: "receipt",
      attrs: %{
        "id" => "group-message-1",
        "from" => "fixture-group@g.us",
        "t" => "1700000000",
        "type" => "read"
      }
    }

    assert {:ok, ^state} = ConnectionProcess.dispatch(receipt, state)
    refute_receive {:connection_event, {:message_receipt_update, _updates}}
    refute_receive {:connection_event, {:message_status, _, _, _, _, _}}
    assert_receive {:sent_node, %Node{tag: "ack"}}
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
    credentials = deterministic_credentials(70)

    assert {:ok, code, _request, credentials} =
             Pairing.request_code(credentials, "+55 11 99999-9999", "ABCD1234")

    primary_ephemeral = deterministic_key_pair(74)
    primary_identity = deterministic_key_pair(75)
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

  test "acknowledges a retry without sent material and reports an internal diagnostic", %{
    state: state
  } do
    receipt = retry_receipt("missing-message", "5521999999999:3@s.whatsapp.net")

    assert {:ok, _state} = ConnectionProcess.dispatch(receipt, state)

    refute_receive {:connection_event, {:message_status, _, _, _, _, _}}
    assert_receive {:diagnostic, {:retry_unsupported, :sent_message_not_found}}
    assert_receive {:sent_node, %Node{tag: "ack", attrs: %{"class" => "receipt"}}}
  end

  test "re-encrypts a retry bundle for the requesting device with the original id", %{
    state: state
  } do
    {state, remote, receipt} = retry_state(state, 2)

    assert {:ok, updated_state} = ConnectionProcess.dispatch(receipt, state)
    assert updated_state.retry_counts[{"message-1", receipt.attrs["participant"]}] == 1

    assert_receive {:sent_node, %Node{tag: "message", attrs: attrs} = resent}
    assert attrs["id"] == "message-1"
    assert attrs["to"] == receipt.attrs["participant"]

    encrypted =
      resent
      |> NodeUtils.child("participants")
      |> NodeUtils.child("to")
      |> NodeUtils.child("enc")

    assert encrypted.attrs["type"] == "pkmsg"
    assert encrypted.attrs["count"] == "1"

    assert {:ok, padded, _record, 7} =
             SessionCipher.decrypt_pre_key(nil, encrypted.content, remote)

    padding = :binary.last(padded)
    decoded = padded |> binary_part(0, byte_size(padded) - padding) |> Message.decode()
    assert decoded.extendedTextMessage.text == "retry me"

    refute_receive {:connection_event, {:message_status, _, _, _, _, _}}
    assert_receive {:sent_node, %Node{tag: "ack", attrs: %{"class" => "receipt"}}}
  end

  test "bounds duplicate retries per message and requester", %{state: state} do
    {state, _remote, receipt} = retry_state(state, 2)

    assert {:ok, state} = ConnectionProcess.dispatch(receipt, state)
    assert_receive {:sent_node, %Node{tag: "message"}}
    assert_receive {:sent_node, %Node{tag: "ack"}}

    assert {:ok, state} = ConnectionProcess.dispatch(receipt, state)
    assert_receive {:sent_node, %Node{tag: "message"}}
    assert_receive {:sent_node, %Node{tag: "ack"}}

    assert {:ok, state} = ConnectionProcess.dispatch(receipt, state)
    assert_receive {:diagnostic, {:retry_unsupported, :retry_limit_reached}}
    assert_receive {:sent_node, %Node{tag: "ack"}}
    refute_receive {:sent_node, %Node{tag: "message"}}
    assert state.retry_counts[{"message-1", receipt.attrs["participant"]}] == 2
  end

  test "retains only the configured number of outbound retry materials", %{state: state} do
    state =
      Map.merge(state, %{
        phase: :transport,
        sent_messages: %{},
        sent_message_order: [],
        sent_message_limit: 1,
        retry_counts: %{{"message-1", "device"} => 1}
      })

    first = %Node{tag: "message", attrs: %{"id" => "message-1"}}
    second = %Node{tag: "message", attrs: %{"id" => "message-2"}}
    first_material = Sender.retry_material("first@s.whatsapp.net", "first")
    second_material = Sender.retry_material("second@s.whatsapp.net", "second")

    assert {:reply, :ok, state} =
             ConnectionProcess.handle_call({:relay, first, first_material}, self(), state)

    assert {:reply, :ok, state} =
             ConnectionProcess.handle_call({:relay, second, second_material}, self(), state)

    assert state.sent_messages == %{"message-2" => second_material}
    assert state.sent_message_order == ["message-2"]
    assert state.retry_counts == %{}
  end

  test "acknowledges a retry with a malformed requester instead of crashing", %{state: state} do
    state =
      Map.merge(state, %{
        sent_messages: %{
          "message-1" => Sender.retry_material("5521999999999@s.whatsapp.net", "retry me")
        },
        retry_counts: %{},
        max_retry_count: 2
      })

    receipt = retry_receipt("message-1", "not-a-jid")

    assert {:ok, _state} = ConnectionProcess.dispatch(receipt, state)
    assert_receive {:diagnostic, {:retry_unsupported, :invalid_retry_requester}}
    assert_receive {:sent_node, %Node{tag: "ack"}}
  end

  test "does not resend cached content to a requester outside the original conversation", %{
    state: state
  } do
    {state, _remote, receipt} = retry_state(state, 2)

    state =
      put_in(
        state.sent_messages["message-1"],
        Sender.retry_material("5531999999999@s.whatsapp.net", "private text")
      )

    assert {:ok, _state} = ConnectionProcess.dispatch(receipt, state)
    assert_receive {:diagnostic, {:retry_unsupported, :retry_requester_mismatch}}
    assert_receive {:sent_node, %Node{tag: "ack"}}
    refute_receive {:sent_node, %Node{tag: "message"}}
  end

  test "counts failed retry attempts toward the per-requester limit", %{state: state} do
    requester = "5521999999999:3@s.whatsapp.net"

    state =
      Map.merge(state, %{
        credentials: %{
          deterministic_credentials(30)
          | me: %{id: "5511000000000:2@s.whatsapp.net", lid: "123456789:2@lid"}
        },
        session_path: nil,
        sent_messages: %{
          "message-1" => Sender.retry_material("5521999999999@s.whatsapp.net", "retry me")
        },
        retry_counts: %{},
        max_retry_count: 2
      })

    receipt = retry_receipt("message-1", requester)

    assert {:ok, state} = ConnectionProcess.dispatch(receipt, state)
    assert state.retry_counts[{"message-1", requester}] == 1
    assert_receive {:diagnostic, {:retry_unsupported, :missing_session}}
    assert_receive {:sent_node, %Node{tag: "ack"}}

    assert {:ok, state} = ConnectionProcess.dispatch(receipt, state)
    assert state.retry_counts[{"message-1", requester}] == 2
    assert_receive {:diagnostic, {:retry_unsupported, :missing_session}}
    assert_receive {:sent_node, %Node{tag: "ack"}}

    assert {:ok, state} = ConnectionProcess.dispatch(receipt, state)
    assert state.retry_counts[{"message-1", requester}] == 2
    assert_receive {:diagnostic, {:retry_unsupported, :retry_limit_reached}}
    assert_receive {:sent_node, %Node{tag: "ack"}}
  end

  test "redacts retained message content from formatted process status" do
    status = %{
      log: [{:in, {:relay, %{text: "secret text"}}}],
      message: {:relay, %{text: "secret text"}},
      reason: {:error, %{text: "secret text"}},
      state: %{
        pending_queries: %{"query" => {:prekeys, %{private: "secret text"}}},
        sent_messages: %{
          "message-1" => Sender.retry_material("5521999999999@s.whatsapp.net", "secret text")
        }
      }
    }

    formatted = ConnectionProcess.format_status(status)
    refute inspect(formatted) =~ "secret text"
    assert formatted.log == :redacted
    assert formatted.message == :redacted
    assert formatted.reason == :redacted
    assert formatted.state.pending_queries == :redacted
    assert formatted.state.sent_messages == {:redacted, 1}
  end

  test "installs a batched retry bundle once and advances its Signal session", %{state: state} do
    {state, remote, receipt} = retry_state(state, 2)

    receipt = %{
      receipt
      | content:
          receipt.content ++
            [
              %Node{
                tag: "list",
                content: [%Node{tag: "item", attrs: %{"id" => "message-2"}}]
              }
            ]
    }

    state =
      put_in(
        state.sent_messages["message-2"],
        Sender.retry_material("5521999999999@s.whatsapp.net", "second retry")
      )

    assert {:ok, _state} = ConnectionProcess.dispatch(receipt, state)
    assert_receive {:sent_node, %Node{tag: "message", attrs: %{"id" => "message-1"}} = first}
    assert_receive {:sent_node, %Node{tag: "message", attrs: %{"id" => "message-2"}} = second}

    first_encrypted = encrypted_retry(first)
    second_encrypted = encrypted_retry(second)
    assert first_encrypted.attrs["type"] == "pkmsg"
    assert second_encrypted.attrs["type"] == "pkmsg"

    assert {:ok, first_padded, remote_record, 7} =
             SessionCipher.decrypt_pre_key(nil, first_encrypted.content, remote)

    remote = %{remote | pre_keys: %{}}

    assert {:ok, second_padded, _remote_record, 7} =
             SessionCipher.decrypt_pre_key(remote_record, second_encrypted.content, remote)

    assert decoded_text(first_padded) == "retry me"
    assert decoded_text(second_padded) == "second retry"
    assert_receive {:sent_node, %Node{tag: "ack"}}
  end

  test "does not reuse a session after the requester registration changes", %{state: state} do
    {state, _remote, receipt} = retry_state(state, 3)

    assert {:ok, state} = ConnectionProcess.dispatch(receipt, state)
    assert_receive {:sent_node, %Node{tag: "message"}}
    assert_receive {:sent_node, %Node{tag: "ack"}}

    receipt = %{
      retry_receipt("message-1", receipt.attrs["participant"])
      | content: [
          %Node{tag: "retry", attrs: %{"count" => "2"}},
          %Node{tag: "registration", content: <<4_294_967_295::32>>}
        ]
    }

    assert {:ok, _state} = ConnectionProcess.dispatch(receipt, state)
    assert_receive {:diagnostic, {:retry_unsupported, :registration_mismatch}}
    assert_receive {:sent_node, %Node{tag: "ack"}}
    refute_receive {:sent_node, %Node{tag: "message"}}
  end

  test "acknowledges a retry even when resend transmission fails", %{state: state} do
    {state, _remote, receipt} = retry_state(state, 2)
    test_pid = self()

    state = %{
      state
      | node_sender: fn
          %Node{tag: "message"} ->
            {:error, :transport_closed}

          node ->
            send(test_pid, {:sent_node, node})
            :ok
        end
    }

    assert {:ok, state} = ConnectionProcess.dispatch(receipt, state)
    assert state.retry_counts[{"message-1", receipt.attrs["participant"]}] == 1
    assert_receive {:diagnostic, {:retry_unsupported, :transport_closed}}
    assert_receive {:sent_node, %Node{tag: "ack"}}
  end

  test "supports a retry from the recipient primary device", %{state: state} do
    {state, _remote, receipt} = retry_state(state, 2)

    receipt = %{
      receipt
      | attrs: Map.put(receipt.attrs, "participant", "5521999999999@s.whatsapp.net")
    }

    assert {:ok, _state} = ConnectionProcess.dispatch(receipt, state)

    assert_receive {:sent_node,
                    %Node{
                      tag: "message",
                      attrs: %{"id" => "message-1", "to" => "5521999999999@s.whatsapp.net"}
                    }}

    assert_receive {:sent_node, %Node{tag: "ack"}}
  end

  test "does not transmit a retry when the advanced Signal state cannot be persisted", %{
    state: state
  } do
    {state, _remote, receipt} = retry_state(state, 2)
    missing_parent = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}")
    state = %{state | session_path: Path.join(missing_parent, "session.json")}

    assert {:ok, state} = ConnectionProcess.dispatch(receipt, state)
    assert state.retry_counts[{"message-1", receipt.attrs["participant"]}] == 1
    assert_receive {:diagnostic, {:retry_unsupported, {:store, _reason}}}
    assert_receive {:sent_node, %Node{tag: "ack"}}
    refute_receive {:sent_node, %Node{tag: "message"}}
  end

  test "applies persisted credential events without writing stale snapshots again" do
    old_credentials = deterministic_credentials(40)
    new_credentials = %{old_credentials | next_pre_key_id: 42}

    state = %{
      credentials: old_credentials,
      session_path: "/missing/session.json",
      subscribers: %{}
    }

    assert {:noreply, updated_state} =
             Client.handle_info({:connection_event, {:credentials, new_credentials}}, state)

    assert updated_state.credentials == new_credentials
  end

  test "injected node transport records an inbound message receipt independently of projection",
       %{
         state: state
       } do
    content = %Message{
      extendedTextMessage: %Message.ExtendedTextMessage{text: "injected transport"}
    }

    {local, message, raw} = encrypted_incoming_message(content)

    state = state |> Map.put(:credentials, local) |> Map.put(:session_path, nil)
    assert {:ok, _state} = ConnectionProcess.dispatch(message, state)

    assert_receive {:sent_node,
                    %Node{
                      tag: "receipt",
                      attrs: %{
                        "id" => "incoming-integration-1",
                        "to" => "5521999999999@s.whatsapp.net"
                      }
                    }}

    assert_receive {:connection_event, {:credentials, _credentials}}
    assert_receive {:connection_event, {:messages_upsert, [envelope], :notify, nil}}
    assert envelope.key.id == "incoming-integration-1"
    assert envelope.content == content
    assert envelope.raw_content == raw
    assert envelope.timestamp == ~U[2023-11-14 22:13:20Z]

    assert_receive {:connection_event,
                    {:text_message,
                     %{
                       id: "incoming-integration-1",
                       chat_jid: "5521999999999@s.whatsapp.net"
                     } = metadata, "injected transport"}}

    public = Client.public_message(envelope)
    assert public.key.id == metadata.id
    assert public.key.remote_jid == metadata.chat_jid
    assert public.key.from_me == metadata.from_me
    assert public.timestamp == metadata.timestamp
  end

  test "offline media emits an append upsert and receipt without a text projection", %{
    state: state
  } do
    content = %Message{imageMessage: %Message.ImageMessage{caption: "fixture image"}}

    {local, message, raw} =
      encrypted_incoming_message(content, %{
        "id" => "incoming-media-1",
        "offline" => "1"
      })

    state = state |> Map.put(:credentials, local) |> Map.put(:session_path, nil)
    assert {:ok, _state} = ConnectionProcess.dispatch(message, state)
    assert_receive {:sent_node, %Node{tag: "receipt"}}
    assert_receive {:connection_event, {:messages_upsert, [envelope], :append, nil}}
    assert envelope.content.imageMessage.caption == "fixture image"
    assert envelope.raw_content == raw
    refute_receive {:connection_event, {:text_message, _, _}}
  end

  test "client projects complete envelopes into a public upsert batch", %{state: state} do
    content = %Message{conversation: "public upsert"}
    {local, message, _raw} = encrypted_incoming_message(content)
    state = state |> Map.put(:credentials, local) |> Map.put(:session_path, nil)
    assert {:ok, _state} = ConnectionProcess.dispatch(message, state)
    assert_receive {:connection_event, {:messages_upsert, [envelope], :notify, nil}}

    client_state = %{subscribers: %{self() => make_ref()}}

    assert {:noreply, ^client_state} =
             Client.handle_info(
               {:connection_event, {:messages_upsert, [envelope], :notify, nil}},
               client_state
             )

    client = self()

    assert_receive {:baileys, ^client,
                    {:messages_upsert,
                     %Baileys.MessagesUpsert{
                       messages: [%Baileys.Message{content: ^content}],
                       type: :notify,
                       request_id: nil
                     }}}
  end

  defp retry_state(state, max_retry_count) do
    local = %{
      deterministic_credentials(10)
      | me: %{id: "5511000000000:2@s.whatsapp.net", lid: "123456789:2@lid"}
    }

    remote = deterministic_credentials(20)
    remote_pre_key = deterministic_key_pair(29)
    remote = %{remote | pre_keys: %{7 => remote_pre_key}}
    requester = "5521999999999:3@s.whatsapp.net"

    receipt = %{
      retry_receipt("message-1", requester)
      | content: [
          %Node{tag: "retry", attrs: %{"count" => "1", "id" => "message-1", "v" => "1"}},
          %Node{tag: "registration", content: <<remote.registration_id::32>>},
          %Node{
            tag: "keys",
            content: [
              %Node{tag: "type", content: <<5>>},
              %Node{tag: "identity", content: remote.signed_identity_key.public},
              %Node{
                tag: "key",
                content: [
                  %Node{tag: "id", content: <<7::24>>},
                  %Node{tag: "value", content: remote_pre_key.public}
                ]
              },
              %Node{
                tag: "skey",
                content: [
                  %Node{tag: "id", content: <<remote.signed_pre_key.key_id::24>>},
                  %Node{tag: "value", content: remote.signed_pre_key.key_pair.public},
                  %Node{tag: "signature", content: remote.signed_pre_key.signature}
                ]
              }
            ]
          }
        ]
    }

    state =
      state
      |> Map.put(:credentials, local)
      |> Map.put(:session_path, nil)
      |> Map.put(:sent_messages, %{
        "message-1" => Sender.retry_material("5521999999999@s.whatsapp.net", "retry me")
      })
      |> Map.put(:retry_counts, %{})
      |> Map.put(:max_retry_count, max_retry_count)

    {state, remote, receipt}
  end

  defp retry_receipt(id, requester) do
    %Node{
      tag: "receipt",
      attrs: %{
        "id" => id,
        "from" => "5521999999999@s.whatsapp.net",
        "participant" => requester,
        "type" => "retry"
      }
    }
  end

  defp encrypted_retry(stanza) do
    stanza
    |> NodeUtils.child("participants")
    |> NodeUtils.child("to")
    |> NodeUtils.child("enc")
  end

  defp decoded_text(padded) do
    padding = :binary.last(padded)
    decoded = padded |> binary_part(0, byte_size(padded) - padding) |> Message.decode()
    decoded.extendedTextMessage.text
  end

  defp encrypted_incoming_message(content, attrs \\ %{}) do
    local = %{deterministic_credentials(50) | me: %{id: "5511000000000:2@s.whatsapp.net"}}
    local_pre_key = deterministic_key_pair(59)
    local = %{local | pre_keys: %{7 => local_pre_key}}
    remote = deterministic_credentials(60)

    bundle = %{
      registration_id: local.registration_id,
      identity_key: <<5, local.signed_identity_key.public::binary>>,
      signed_pre_key: %{
        key_id: local.signed_pre_key.key_id,
        public: <<5, local.signed_pre_key.key_pair.public::binary>>,
        signature: local.signed_pre_key.signature
      },
      pre_key: %{key_id: 7, public: <<5, local_pre_key.public::binary>>}
    }

    {:ok, remote_record} = SessionBuilder.init_outgoing(nil, bundle, remote.signed_identity_key)
    raw = Protobuf.encode(content)
    plaintext = raw <> <<1>>

    {:ok, :pkmsg, ciphertext, _remote_record} =
      SessionCipher.encrypt(
        remote_record,
        plaintext,
        remote.signed_identity_key,
        remote.registration_id
      )

    attrs =
      Map.merge(
        %{
          "id" => "incoming-integration-1",
          "from" => "5521999999999@s.whatsapp.net",
          "t" => "1700000000"
        },
        attrs
      )

    message = %Node{
      tag: "message",
      attrs: attrs,
      content: [%Node{tag: "enc", attrs: %{"type" => "pkmsg"}, content: ciphertext}]
    }

    {local, message, raw}
  end

  defp deterministic_credentials(seed) do
    identity = deterministic_key_pair(seed)
    signed_key = deterministic_key_pair(seed + 1)

    %Credentials{
      noise_key: deterministic_key_pair(seed + 2),
      pairing_ephemeral_key: deterministic_key_pair(seed + 3),
      signed_identity_key: identity,
      signed_pre_key: %{
        key_pair: signed_key,
        key_id: 1,
        signature: XEdDSA.sign(<<5, signed_key.public::binary>>, identity.private)
      },
      registration_id: seed,
      adv_secret_key: :binary.copy(<<seed>>, 32)
    }
  end

  defp deterministic_key_pair(seed) do
    private = :binary.copy(<<seed>>, 32)
    {public, ^private} = :crypto.generate_key(:ecdh, :x25519, private)
    %{public: public, private: private}
  end
end
