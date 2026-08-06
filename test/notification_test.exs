defmodule Baileys.Messages.NotificationTest do
  use ExUnit.Case, async: true

  alias Baileys.Auth.Credentials
  alias Baileys.Binary.Node
  alias Baileys.Client
  alias Baileys.Messages.Notification

  setup do
    %{credentials: %Credentials{me: %{id: "local-user:2@s.whatsapp.net"}}}
  end

  test "decodes profile picture contact and group system updates", %{credentials: credentials} do
    node = %Node{
      tag: "notification",
      attrs: %{
        "id" => "picture-1",
        "from" => "fixture-group@g.us",
        "type" => "picture",
        "t" => "1700000000"
      },
      content: [
        %Node{
          tag: "set",
          attrs: %{"id" => "picture-hash", "author" => "actor@s.whatsapp.net"}
        }
      ]
    }

    assert {:ok, effects, ^credentials} = Notification.decode(node, credentials)

    assert [
             {:contacts_update, [%{id: "fixture-group@g.us", img_url: :changed}]},
             {:messages_upsert, [envelope], :append, nil}
           ] = effects

    assert envelope.stub_type == :group_change_icon
    assert envelope.stub_parameters == ["picture-hash"]
    assert envelope.key.participant == "actor@s.whatsapp.net"
  end

  test "decodes blocklist and disappearing-mode account sync", %{credentials: credentials} do
    blocklist = %Node{
      tag: "notification",
      attrs: %{"id" => "account-1", "from" => "s.whatsapp.net", "type" => "account_sync"},
      content: [
        %Node{
          tag: "blocklist",
          content: [
            %Node{tag: "item", attrs: %{"jid" => "blocked@s.whatsapp.net", "action" => "block"}},
            %Node{tag: "item", attrs: %{"jid" => "open@s.whatsapp.net", "action" => "unblock"}}
          ]
        }
      ]
    }

    assert {:ok,
            [
              {:blocklist_update, %{blocklist: ["blocked@s.whatsapp.net"], type: :add}},
              {:blocklist_update, %{blocklist: ["open@s.whatsapp.net"], type: :remove}}
            ], ^credentials} = Notification.decode(blocklist, credentials)

    disappearing = %Node{
      tag: "notification",
      attrs: %{"id" => "account-2", "from" => "s.whatsapp.net", "type" => "account_sync"},
      content: [
        %Node{
          tag: "disappearing_mode",
          attrs: %{"duration" => "86400", "t" => "1700000000"}
        }
      ]
    }

    assert {:ok, [{:settings_update, settings}], updated} =
             Notification.decode(disappearing, credentials)

    assert settings.default_disappearing_mode.ephemeral_expiration == 86_400
    assert settings.default_disappearing_mode.ephemeral_setting_timestamp == 1_700_000_000
    assert updated.account_settings == settings
  end

  test "decodes successful and failed media retry updates", %{credentials: credentials} do
    success =
      media_retry_node([
        %Node{
          tag: "encrypt",
          content: [
            %Node{tag: "enc_p", content: <<1, 2, 3>>},
            %Node{tag: "enc_iv", content: <<4, 5>>}
          ]
        }
      ])

    assert {:ok, [{:media_update, [update]}], ^credentials} =
             Notification.decode(success, credentials)

    assert update.key.id == "media-1"
    assert update.key.remote_jid == "chat@s.whatsapp.net"
    assert update.key.from_me
    assert update.media == %{ciphertext: <<1, 2, 3>>, iv: <<4, 5>>}
    assert update.error == nil

    failure = media_retry_node([%Node{tag: "error", attrs: %{"code" => "404"}}])

    assert {:ok, [{:media_update, [%{error: error}]}], ^credentials} =
             Notification.decode(failure, credentials)

    assert error.code == 404
    assert error.attrs == %{"code" => "404"}
  end

  test "stores trusted-contact privacy tokens under the sender LID", %{credentials: credentials} do
    timestamp = System.system_time(:second)

    node = %Node{
      tag: "notification",
      attrs: %{
        "id" => "token-1",
        "from" => "contact@s.whatsapp.net",
        "sender_lid" => "9000@lid",
        "type" => "privacy_token"
      },
      content: [
        %Node{
          tag: "tokens",
          content: [
            %Node{
              tag: "token",
              attrs: %{"type" => "trusted_contact", "t" => Integer.to_string(timestamp)},
              content: <<9, 8, 7>>
            }
          ]
        }
      ]
    }

    assert {:ok, [], updated} = Notification.decode(node, credentials)
    assert updated.privacy_tokens["9000@lid"] == %{token: <<9, 8, 7>>, timestamp: timestamp}
  end

  test "projects notification effects into typed public events" do
    state = %{subscribers: %{self() => make_ref()}}

    assert {:noreply, ^state} =
             Client.handle_info(
               {:connection_event,
                {:contacts_update, [%{id: "contact@s.whatsapp.net", img_url: :changed}]}},
               state
             )

    assert_receive {:baileys, _client,
                    {:contacts_update,
                     [%Baileys.ContactUpdate{id: "contact@s.whatsapp.net", img_url: :changed}]}}

    settings = %{
      default_disappearing_mode: %{
        ephemeral_expiration: 86_400,
        ephemeral_setting_timestamp: 1_700_000_000
      }
    }

    assert {:noreply, ^state} =
             Client.handle_info({:connection_event, {:settings_update, settings}}, state)

    assert_receive {:baileys, _client,
                    {:settings_update,
                     %Baileys.AccountSettings{
                       default_disappearing_mode: %Baileys.DefaultDisappearingMode{
                         ephemeral_expiration: 86_400
                       }
                     }}}

    assert {:noreply, ^state} =
             Client.handle_info(
               {:connection_event,
                {:blocklist_update, %{blocklist: ["blocked@s.whatsapp.net"], type: :add}}},
               state
             )

    assert_receive {:baileys, _client,
                    {:blocklist_update,
                     %Baileys.BlocklistUpdate{
                       blocklist: ["blocked@s.whatsapp.net"],
                       type: :add
                     }}}

    media_update = %{
      key: %{
        remote_jid: "chat@s.whatsapp.net",
        remote_jid_alt: nil,
        remote_jid_username: nil,
        from_me: false,
        id: "media-1",
        participant: nil,
        participant_alt: nil,
        participant_username: nil,
        addressing_mode: :pn,
        server_id: nil,
        view_once?: false
      },
      media: %{ciphertext: <<1>>, iv: <<2>>},
      error: nil
    }

    assert {:noreply, ^state} =
             Client.handle_info(
               {:connection_event, {:messages_media_update, [media_update]}},
               state
             )

    assert_receive {:baileys, _client,
                    {:messages_media_update,
                     [
                       %Baileys.MediaUpdate{
                         key: %Baileys.MessageKey{id: "media-1"},
                         media: %Baileys.MediaRetryData{ciphertext: <<1>>, iv: <<2>>}
                       }
                     ]}}
  end

  defp media_retry_node(extra) do
    %Node{
      tag: "notification",
      attrs: %{"id" => "media-1", "from" => "s.whatsapp.net", "type" => "mediaretry"},
      content: [
        %Node{
          tag: "rmr",
          attrs: %{
            "jid" => "chat@s.whatsapp.net",
            "from_me" => "true",
            "participant" => "actor@s.whatsapp.net"
          }
        }
        | extra
      ]
    }
  end
end
