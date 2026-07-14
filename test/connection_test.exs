defmodule BaileysExo.ConnectionProcessTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.{Node, NodeUtils}
  alias BaileysExo.Client
  alias BaileysExo.ConnectionProcess
  alias BaileysExo.Crypto.XEdDSA
  alias BaileysExo.Messages.Sender
  alias BaileysExo.Proto.{ADVSignedDeviceIdentity, Message}
  alias BaileysExo.Signal.{SenderKey, SessionBuilder, SessionCipher}
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

  test "acknowledges every recognized malformed notification category once", %{state: state} do
    for type <- [
          "picture",
          "account_sync",
          "mediaretry",
          "devices",
          "encrypt",
          "server_sync",
          "privacy_token"
        ] do
      notification = %Node{
        tag: "notification",
        attrs: %{
          "id" => "notification-#{type}",
          "from" => "s.whatsapp.net",
          "type" => type
        }
      }

      assert {:ok, ^state} = ConnectionProcess.dispatch(notification, state)

      assert_receive {:sent_node,
                      %Node{
                        tag: "ack",
                        attrs: %{
                          "class" => "notification",
                          "id" => "notification-" <> ^type,
                          "to" => "s.whatsapp.net",
                          "type" => ^type
                        }
                      }}

      refute_receive {:sent_node, %Node{tag: "ack"}}
    end

    refute_receive {:connection_event, _event}
  end

  test "routes public notification effects before acknowledging", %{state: state} do
    picture = %Node{
      tag: "notification",
      attrs: %{
        "id" => "picture-1",
        "from" => "contact@s.whatsapp.net",
        "type" => "picture"
      },
      content: [%Node{tag: "set", attrs: %{"id" => "hash"}}]
    }

    state = Map.put(state, :session_path, nil)
    assert {:ok, ^state} = ConnectionProcess.dispatch(picture, state)

    assert_receive {:connection_event,
                    {:contacts_update, [%{id: "contact@s.whatsapp.net", img_url: :changed}]}}

    assert_receive {:sent_node,
                    %Node{tag: "ack", attrs: %{"id" => "picture-1", "type" => "picture"}}}
  end

  test "removes device and changed-identity sessions internally", %{state: state} do
    credentials = %{
      state.credentials
      | sessions: %{
          "contact:1@s.whatsapp.net" => %{record: 1},
          "contact:2@s.whatsapp.net" => %{record: 2},
          "9000:2@lid" => %{record: 4},
          "9000:3@lid" => %{record: 5},
          "other:1@s.whatsapp.net" => %{record: 3}
        },
        lid_mappings: %{"contact@s.whatsapp.net" => "9000@lid"}
    }

    remove = %Node{
      tag: "notification",
      attrs: %{"id" => "devices-1", "from" => "contact@s.whatsapp.net", "type" => "devices"},
      content: [
        %Node{
          tag: "remove",
          content: [%Node{tag: "device", attrs: %{"jid" => "contact:2@s.whatsapp.net"}}]
        }
      ]
    }

    state = state |> Map.put(:credentials, credentials) |> Map.put(:session_path, nil)
    assert {:ok, state} = ConnectionProcess.dispatch(remove, state)
    refute Map.has_key?(state.credentials.sessions, "contact:2@s.whatsapp.net")
    refute Map.has_key?(state.credentials.sessions, "9000:2@lid")
    assert Map.has_key?(state.credentials.sessions, "contact:1@s.whatsapp.net")
    assert_receive {:connection_event, {:credentials, _credentials}}
    assert_receive {:sent_node, %Node{tag: "ack", attrs: %{"id" => "devices-1"}}}

    identity = %Node{
      tag: "notification",
      attrs: %{"id" => "identity-1", "from" => "contact@s.whatsapp.net", "type" => "encrypt"},
      content: [%Node{tag: "identity"}]
    }

    assert {:ok, state} = ConnectionProcess.dispatch(identity, state)
    refute Map.has_key?(state.credentials.sessions, "contact:1@s.whatsapp.net")
    refute Map.has_key?(state.credentials.sessions, "9000:3@lid")
    assert Map.has_key?(state.credentials.sessions, "other:1@s.whatsapp.net")
    assert_receive {:connection_event, {:credentials, _credentials}}
    assert_receive {:sent_node, %Node{tag: "ack", attrs: %{"id" => "identity-1"}}}
  end

  test "replenishes low prekeys before acknowledging the notification", %{state: state} do
    notification = %Node{
      tag: "notification",
      attrs: %{"id" => "prekey-low-1", "from" => "s.whatsapp.net", "type" => "encrypt"},
      content: [%Node{tag: "count", attrs: %{"value" => "2"}}]
    }

    state =
      state
      |> Map.put(:credentials, deterministic_credentials(50))
      |> Map.put(:pending_queries, %{})
      |> Map.put(:session_path, nil)

    assert {:ok, state} = ConnectionProcess.dispatch(notification, state)
    assert map_size(state.pending_queries) == 1
    assert map_size(state.credentials.pre_keys) == 5
    assert_receive {:sent_node, %Node{tag: "iq", attrs: %{"xmlns" => "encrypt"}}}
    assert_receive {:connection_event, {:credentials, %Credentials{}}}
    refute_receive {:sent_node, %Node{tag: "ack"}}

    [query_id] = Map.keys(state.pending_queries)
    reply = %Node{tag: "iq", attrs: %{"id" => query_id, "type" => "result"}}
    assert {:ok, state} = ConnectionProcess.dispatch(reply, state)
    assert state.credentials.first_unuploaded_pre_key_id == 6
    assert_receive {:connection_event, {:credentials, %Credentials{}}}
    assert_receive {:sent_node, %Node{tag: "ack", attrs: %{"id" => "prekey-low-1"}}}
  end

  test "retries failed prekey replenishment before its single acknowledgement", %{state: state} do
    notification = %Node{
      tag: "notification",
      attrs: %{"id" => "prekey-low-failed", "from" => "s.whatsapp.net", "type" => "encrypt"},
      content: [%Node{tag: "count", attrs: %{"value" => "1"}}]
    }

    state =
      state
      |> Map.put(:credentials, deterministic_credentials(51))
      |> Map.put(:pending_queries, %{})
      |> Map.put(:session_path, nil)

    assert {:ok, state} = ConnectionProcess.dispatch(notification, state)
    assert_receive {:sent_node, %Node{tag: "iq"}}
    assert_receive {:connection_event, {:credentials, %Credentials{}}}

    state =
      Enum.reduce(1..3, state, fn attempt, state ->
        [query_id] = Map.keys(state.pending_queries)
        reply = %Node{tag: "iq", attrs: %{"id" => query_id, "type" => "error"}}
        assert {:ok, state} = ConnectionProcess.dispatch(reply, state)

        if attempt < 3 do
          assert_receive {:sent_node, %Node{tag: "iq"}}
          assert_receive {:connection_event, {:credentials, %Credentials{}}}
          refute_receive {:sent_node, %Node{tag: "ack"}}
        end

        state
      end)

    assert state.pending_queries == %{}
    assert_receive {:connection_event, {:error, :prekey_replenishment_failed}}
    assert_receive {:sent_node, %Node{tag: "ack", attrs: %{"id" => "prekey-low-failed"}}}
    refute_receive {:sent_node, %Node{tag: "ack"}}
  end

  test "merges sender credential deltas without overwriting concurrent state", %{state: state} do
    base = %{
      deterministic_credentials(60)
      | sessions: %{"contact:1@s.whatsapp.net" => %{ratchet: :base}}
    }

    updated = %{
      base
      | sessions: %{"contact:1@s.whatsapp.net" => %{ratchet: :sender}},
        lid_mappings: %{"contact@s.whatsapp.net" => "9000@lid"}
    }

    current = %{
      base
      | account_settings: %{
          default_disappearing_mode: %{
            ephemeral_expiration: 86_400,
            ephemeral_setting_timestamp: 1_700_000_000
          }
        }
    }

    state = state |> Map.put(:credentials, current) |> Map.put(:session_path, nil)

    assert {:reply, {:ok, merged}, state} =
             ConnectionProcess.handle_call(
               {:commit_credentials, base, updated},
               self(),
               state
             )

    assert merged.sessions["contact:1@s.whatsapp.net"] == %{ratchet: :sender}
    assert merged.account_settings == current.account_settings
    assert merged.lid_mappings == updated.lid_mappings
    assert_receive {:connection_event, {:credentials, ^merged}}

    conflicted = put_in(current.sessions["contact:1@s.whatsapp.net"], %{ratchet: :receiver})
    state = %{state | credentials: conflicted}

    assert {:reply, {:error, :credentials_conflict}, ^state} =
             ConnectionProcess.handle_call(
               {:commit_credentials, base, updated},
               self(),
               state
             )
  end

  test "persists validated server-sync collections for app-state processing", %{state: state} do
    state = Map.put(state, :session_path, nil)

    state =
      Enum.reduce(
        ["critical_block", "critical_unblock_low", "regular_high", "regular_low", "regular"],
        state,
        fn name, state ->
          notification = %Node{
            tag: "notification",
            attrs: %{
              "id" => "sync-#{name}",
              "from" => "s.whatsapp.net",
              "type" => "server_sync"
            },
            content: [%Node{tag: "collection", attrs: %{"name" => name}}]
          }

          assert {:ok, state} = ConnectionProcess.dispatch(notification, state)
          assert_receive {:connection_event, {:credentials, %Credentials{}}}
          assert_receive {:sent_node, %Node{tag: "ack", attrs: %{"id" => "sync-" <> _}}}
          state
        end
      )

    assert state.credentials.pending_app_state_sync == [
             "critical_block",
             "critical_unblock_low",
             "regular_high",
             "regular_low",
             "regular"
           ]
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

  test "emits typed calls, carries bounded offer metadata and acknowledges once", %{state: state} do
    call = %Node{
      tag: "call",
      attrs: %{
        "id" => "call-stanza-1",
        "from" => "fixture-group@g.us",
        "t" => "1700000000"
      },
      content: [
        %Node{
          tag: "offer",
          attrs: %{
            "call-id" => "call-1",
            "call-creator" => "caller@lid",
            "caller_pn" => "caller@s.whatsapp.net",
            "type" => "group",
            "group-jid" => "fixture-group@g.us"
          },
          content: [%Node{tag: "video"}]
        }
      ]
    }

    assert {:ok, state} = ConnectionProcess.dispatch(call, state)

    assert_receive {:connection_event,
                    {:call,
                     [
                       %{
                         id: "call-1",
                         status: :offer,
                         is_video?: true,
                         is_group?: true
                       }
                     ]}}

    assert_receive {:sent_node,
                    %Node{
                      tag: "ack",
                      attrs: %{
                        "class" => "call",
                        "id" => "call-stanza-1",
                        "to" => "fixture-group@g.us"
                      }
                    }}

    ringing = %Node{
      call
      | attrs: %{call.attrs | "id" => "call-stanza-2"},
        content: [
          %Node{tag: "ringing", attrs: %{"call-id" => "call-1", "from" => "caller@lid"}}
        ]
    }

    assert {:ok, state} = ConnectionProcess.dispatch(ringing, state)

    assert_receive {:connection_event, {:call, [ringing_event]}}
    assert ringing_event.status == :ringing
    assert ringing_event.caller_pn == "caller@s.whatsapp.net"
    assert ringing_event.is_video?
    assert ringing_event.is_group?
    assert ringing_event.group_jid == "fixture-group@g.us"
    assert map_size(state.call_offers) == 1
    assert_receive {:sent_node, %Node{tag: "ack", attrs: %{"id" => "call-stanza-2"}}}

    client_state = %{subscribers: %{self() => make_ref()}}

    assert {:noreply, ^client_state} =
             Client.handle_info({:connection_event, {:call, [ringing_event]}}, client_state)

    assert_receive {:baileys, _client, {:call, [%Baileys.Call{status: :ringing}]}}

    timeout = %Node{
      ringing
      | attrs: %{ringing.attrs | "id" => "call-stanza-3"},
        content: [
          %Node{
            tag: "terminate",
            attrs: %{"call-id" => "call-1", "reason" => "timeout"}
          }
        ]
    }

    assert {:ok, state} = ConnectionProcess.dispatch(timeout, state)
    assert_receive {:connection_event, {:call, [timeout_event]}}
    assert timeout_event.status == :timeout
    assert timeout_event.is_video?
    assert timeout_event.group_jid == "fixture-group@g.us"
    assert state.call_offers == %{}
    assert_receive {:sent_node, %Node{tag: "ack", attrs: %{"id" => "call-stanza-3"}}}
  end

  test "bounds and expires call offer metadata", %{state: state} do
    state =
      state
      |> Map.put(:call_offer_limit, 1)
      |> Map.put(:call_offer_ttl, 100)
      |> Map.put(:monotonic_now, fn -> 0 end)

    state =
      Enum.reduce(["call-1", "call-2"], state, fn id, state ->
        node = call_fixture(id, "offer")
        assert {:ok, state} = ConnectionProcess.dispatch(node, state)
        assert_receive {:connection_event, {:call, [_call]}}
        assert_receive {:sent_node, %Node{tag: "ack"}}
        state
      end)

    assert Map.keys(state.call_offers) == ["call-2"]

    state = Map.put(state, :monotonic_now, fn -> 101 end)
    assert {:ok, state} = ConnectionProcess.dispatch(call_fixture("call-2", "ringing"), state)
    assert_receive {:connection_event, {:call, [ringing]}}
    assert ringing.is_video? == nil
    assert state.call_offers == %{}
    assert_receive {:sent_node, %Node{tag: "ack"}}
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

  test "emits group system upserts before typed effects and acknowledges once", %{state: state} do
    notification = %Node{
      tag: "notification",
      attrs: %{
        "id" => "group-notification-1",
        "from" => "fixture-group@g.us",
        "participant" => "actor@lid",
        "participant_pn" => "actor@s.whatsapp.net",
        "addressing_mode" => "lid",
        "type" => "w:gp2",
        "t" => "1700000000"
      },
      content: [%Node{tag: "subject", attrs: %{"subject" => "New Subject"}}]
    }

    assert {:ok, ^state} = ConnectionProcess.dispatch(notification, state)

    assert_receive {:connection_event,
                    {:messages_upsert, [%{stub_type: :group_change_subject}], :append, nil}}

    assert_receive {:connection_event,
                    {:group_effect, {:groups_update, [%{subject: "New Subject"}]}}}

    assert_receive {:sent_node,
                    %Node{
                      tag: "ack",
                      attrs: %{
                        "class" => "notification",
                        "id" => "group-notification-1",
                        "participant" => "actor@lid",
                        "to" => "fixture-group@g.us",
                        "type" => "w:gp2"
                      }
                    }}

    refute_receive {:sent_node, %Node{tag: "ack"}}
  end

  test "acknowledges and ignores unsupported group operations", %{state: state} do
    notification = %Node{
      tag: "notification",
      attrs: %{
        "id" => "group-notification-unknown",
        "from" => "fixture-group@g.us",
        "type" => "w:gp2",
        "t" => "1700000000"
      },
      content: [%Node{tag: "future-group-operation"}]
    }

    assert {:ok, ^state} = ConnectionProcess.dispatch(notification, state)
    refute_receive {:connection_event, _event}

    assert_receive {:sent_node,
                    %Node{
                      tag: "ack",
                      attrs: %{
                        "class" => "notification",
                        "id" => "group-notification-unknown"
                      }
                    }}
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

  test "processes sender-key distributions and decrypts group skmsg", %{state: state} do
    sender_record = sender_key_record(81)

    distribution_content = %Message{
      senderKeyDistributionMessage: %Message.SenderKeyDistributionMessage{
        groupId: "fixture-group@g.us",
        axolotlSenderKeyDistributionMessage: SenderKey.distribution(sender_record)
      }
    }

    {local, distribution_node, _raw} = encrypted_incoming_message(distribution_content)
    state = state |> Map.put(:credentials, local) |> Map.put(:session_path, nil)
    assert {:ok, state} = ConnectionProcess.dispatch(distribution_node, state)

    sender_key_name =
      SenderKey.record_key("fixture-group@g.us", "5521999999999@s.whatsapp.net")

    assert Map.has_key?(state.credentials.sender_keys, sender_key_name)

    group_content = %Message{conversation: "group sender-key fixture"}
    padded = Protobuf.encode(group_content) <> <<1>>
    assert {:ok, ciphertext, _sender_record} = SenderKey.encrypt(sender_record, padded)

    group_node = %Node{
      tag: "message",
      attrs: %{
        "id" => "group-message-1",
        "from" => "fixture-group@g.us",
        "participant" => "5521999999999@s.whatsapp.net",
        "t" => "1700000000"
      },
      content: [%Node{tag: "enc", attrs: %{"type" => "skmsg"}, content: ciphertext}]
    }

    assert {:ok, _state} = ConnectionProcess.dispatch(group_node, state)
    assert_receive {:sent_node, %Node{tag: "receipt", attrs: %{"to" => "fixture-group@g.us"}}}

    assert_receive {:connection_event,
                    {:messages_upsert, [%{content: ^group_content} = envelope], :notify, nil}}

    assert envelope.key.remote_jid == "fixture-group@g.us"
    assert envelope.key.participant == "5521999999999@s.whatsapp.net"
  end

  test "processes a sender-key distribution before skmsg in the same stanza", %{state: state} do
    sender_record = sender_key_record(82)

    distribution_content = %Message{
      senderKeyDistributionMessage: %Message.SenderKeyDistributionMessage{
        groupId: "fixture-group@g.us",
        axolotlSenderKeyDistributionMessage: SenderKey.distribution(sender_record)
      }
    }

    {local, distribution_node, _raw} = encrypted_incoming_message(distribution_content)
    group_content = %Message{conversation: "combined sender-key fixture"}
    padded = Protobuf.encode(group_content) <> <<1>>
    assert {:ok, ciphertext, _sender_record} = SenderKey.encrypt(sender_record, padded)

    group_node = %Node{
      tag: "message",
      attrs: %{
        "id" => "combined-group-message-1",
        "from" => "fixture-group@g.us",
        "participant" => "5521999999999@s.whatsapp.net",
        "t" => "1700000000"
      },
      content: [
        %Node{tag: "enc", attrs: %{"type" => "future-cipher"}, content: <<1, 2, 3>>},
        %Node{tag: "enc", attrs: %{"type" => "skmsg"}, content: ciphertext},
        hd(distribution_node.content)
      ]
    }

    state = state |> Map.put(:credentials, local) |> Map.put(:session_path, nil)
    assert {:ok, state} = ConnectionProcess.dispatch(group_node, state)

    sender_key_name =
      SenderKey.record_key("fixture-group@g.us", "5521999999999@s.whatsapp.net")

    assert Map.has_key?(state.credentials.sender_keys, sender_key_name)
    assert_receive {:sent_node, %Node{tag: "receipt", attrs: %{"to" => "fixture-group@g.us"}}}

    assert_receive {:connection_event, {:messages_upsert, [envelope], :notify, nil}}
    assert envelope.content.conversation == group_content.conversation
    assert envelope.content.senderKeyDistributionMessage
  end

  test "retries a combined stanza when skmsg fails after a valid distribution", %{state: state} do
    distributed_record = sender_key_record(83)

    distribution_content = %Message{
      senderKeyDistributionMessage: %Message.SenderKeyDistributionMessage{
        groupId: "fixture-group@g.us",
        axolotlSenderKeyDistributionMessage: SenderKey.distribution(distributed_record)
      }
    }

    {local, distribution_node, _raw} = encrypted_incoming_message(distribution_content)
    padded = Protobuf.encode(%Message{conversation: "must not be lost"}) <> <<1>>
    assert {:ok, ciphertext, _record} = SenderKey.encrypt(sender_key_record(84), padded)

    group_node = %Node{
      tag: "message",
      attrs: %{
        "id" => "failed-combined-group-message-1",
        "from" => "fixture-group@g.us",
        "participant" => "5521999999999@s.whatsapp.net",
        "t" => "1700000000"
      },
      content: [
        hd(distribution_node.content),
        %Node{tag: "enc", attrs: %{"type" => "skmsg"}, content: ciphertext}
      ]
    }

    state =
      state
      |> Map.put(:credentials, local)
      |> Map.put(:session_path, nil)
      |> Map.put(:max_retry_count, 5)

    assert {:ok, state} = ConnectionProcess.dispatch(group_node, state)

    sender_key_name =
      SenderKey.record_key("fixture-group@g.us", "5521999999999@s.whatsapp.net")

    assert Map.has_key?(state.credentials.sender_keys, sender_key_name)
    refute_receive {:connection_event, {:messages_upsert, _, _, _}}
    assert_receive {:connection_event, {:error, {:message_decrypt_failed, %{retry?: true}}}}
    assert_receive {:sent_node, %Node{tag: "receipt", attrs: %{"type" => "retry"}}}
    assert_receive {:sent_node, %Node{tag: "ack", attrs: %{"error" => "500"}}}
  end

  test "bounds missing sender-key retry receipts without crashing", %{state: state} do
    node = %Node{
      tag: "message",
      attrs: %{
        "id" => "missing-sender-key-1",
        "from" => "fixture-group@g.us",
        "participant" => "remote-user:3@s.whatsapp.net",
        "t" => "1700000000"
      },
      content: [%Node{tag: "enc", attrs: %{"type" => "skmsg"}, content: <<51, 1>>}]
    }

    state =
      state
      |> Map.put(:credentials, %{
        deterministic_credentials(10)
        | me: %{id: "5511000000000:2@s.whatsapp.net"},
          account: %ADVSignedDeviceIdentity{
            details: <<1>>,
            accountSignatureKey: <<2, 3>>,
            accountSignature: <<4>>,
            deviceSignature: <<5>>
          }
      })
      |> Map.put(:incoming_retry_counts, %{})
      |> Map.put(:max_retry_count, 5)

    state =
      Enum.reduce(1..7, state, fn expected_attempt, state ->
        assert {:ok, state} = ConnectionProcess.dispatch(node, state)
        assert_receive {:connection_event, {:error, {:message_decrypt_failed, diagnostic}}}
        assert diagnostic.reason in [:missing_sender_key, :invalid_sender_key_message]
        assert diagnostic.attempt == min(expected_attempt, 5)
        assert diagnostic.retry? == expected_attempt <= 5

        if expected_attempt <= 5 do
          assert_receive {:sent_node,
                          %Node{
                            tag: "receipt",
                            attrs: %{"id" => "missing-sender-key-1", "type" => "retry"},
                            content: [%Node{tag: "retry", attrs: %{"count" => count}} | _]
                          } = retry}

          assert count == Integer.to_string(expected_attempt)

          if expected_attempt == 2 do
            keys = NodeUtils.child(retry, "keys")
            identity = NodeUtils.child(keys, "device-identity")
            decoded = ADVSignedDeviceIdentity.decode(identity.content)
            assert decoded.accountSignatureKey == <<2, 3>>
          end
        else
          refute_receive {:sent_node, %Node{tag: "receipt", attrs: %{"type" => "retry"}}}
        end

        assert_receive {:sent_node, %Node{tag: "ack", attrs: %{"error" => "500"}}}
        state
      end)

    assert state.incoming_retry_counts[
             {"missing-sender-key-1", "remote-user:3@s.whatsapp.net"}
           ] == 5
  end

  test "applies a connection-wide budget after retry counter eviction", %{state: state} do
    state =
      state
      |> Map.put(:credentials, %{
        deterministic_credentials(10)
        | me: %{id: "5511000000000:2@s.whatsapp.net"}
      })
      |> Map.put(:incoming_retry_limit, 1)
      |> Map.put(:incoming_retry_budget, 2)

    state =
      Enum.reduce(1..3, state, fn sequence, state ->
        node = %Node{
          tag: "message",
          attrs: %{
            "id" => "budget-#{sequence}",
            "from" => "fixture-group@g.us",
            "participant" => "remote-user:3@s.whatsapp.net",
            "t" => "1700000000"
          },
          content: [%Node{tag: "enc", attrs: %{"type" => "skmsg"}, content: <<51, 1>>}]
        }

        assert {:ok, state} = ConnectionProcess.dispatch(node, state)
        assert_receive {:connection_event, {:error, {:message_decrypt_failed, diagnostic}}}
        assert diagnostic.retry? == sequence <= 2

        if sequence <= 2 do
          assert_receive {:sent_node, %Node{tag: "receipt", attrs: %{"type" => "retry"}}}
        else
          refute_receive {:sent_node, %Node{tag: "receipt", attrs: %{"type" => "retry"}}}
        end

        assert_receive {:sent_node, %Node{tag: "ack", attrs: %{"error" => "500"}}}
        state
      end)

    assert state.incoming_retry_total == 2
    assert map_size(state.incoming_retry_counts) == 1
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

  defp call_fixture(id, status) do
    content =
      if status == "offer" do
        [%Node{tag: "video"}]
      end

    %Node{
      tag: "call",
      attrs: %{
        "id" => "stanza-#{id}-#{status}",
        "from" => "caller@s.whatsapp.net",
        "t" => "1700000000"
      },
      content: [
        %Node{
          tag: status,
          attrs: %{"call-id" => id, "from" => "caller@s.whatsapp.net"},
          content: content
        }
      ]
    }
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

  defp sender_key_record(seed) do
    signing_key = deterministic_key_pair(seed)

    SenderKey.new_record(
      SenderKey.new_state(seed, 0, :binary.copy(<<seed + 1>>, 32), signing_key)
    )
  end
end
