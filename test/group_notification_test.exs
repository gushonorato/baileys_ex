defmodule BaileysExo.Messages.GroupNotificationTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.Node
  alias BaileysExo.Client
  alias BaileysExo.Messages.GroupNotification

  setup do
    credentials = %Credentials{
      me: %{id: "local-user:2@s.whatsapp.net", lid: "local-lid:2@lid"}
    }

    %{credentials: credentials}
  end

  test "decodes group creation metadata and participants", %{credentials: credentials} do
    group = %Node{
      tag: "group",
      attrs: %{
        "id" => "fixture-group",
        "subject" => "Fixture Group",
        "creator" => "owner@s.whatsapp.net",
        "creation" => "1700000000",
        "size" => "1",
        "addressing_mode" => "lid"
      },
      content: [
        %Node{tag: "announcement"},
        %Node{
          tag: "participant",
          attrs: %{
            "jid" => "member@lid",
            "phone_number" => "member@s.whatsapp.net",
            "type" => "admin"
          }
        }
      ]
    }

    node = notification(%Node{tag: "create", content: [group]})

    assert {:ok, envelope, {:groups_upsert, [metadata]}} =
             GroupNotification.decode(node, credentials)

    assert envelope.stub_type == :group_create
    assert envelope.raw_content == nil
    assert metadata.id == "fixture-group@g.us"
    assert metadata.subject == "Fixture Group"
    assert metadata.announce?

    assert [%{id: "member@lid", phone_number: "member@s.whatsapp.net", admin: :admin}] =
             metadata.participants
  end

  test "decodes participant, metadata and ephemeral operations", %{credentials: credentials} do
    participant = %Node{
      tag: "participant",
      attrs: %{"jid" => "member@s.whatsapp.net", "lid" => "member@lid"}
    }

    for {operation, action} <- [
          {"add", :add},
          {"remove", :remove},
          {"promote", :promote},
          {"demote", :demote}
        ] do
      node = notification(%Node{tag: operation, content: [participant]})

      assert {:ok, _envelope, {:group_participants_update, update}} =
               GroupNotification.decode(node, credentials)

      assert update.action == action
      assert [%{id: "member@s.whatsapp.net", lid: "member@lid"}] = update.participants
    end

    assert {:ok, subject, {:groups_update, [%{subject: "New Subject"}]}} =
             GroupNotification.decode(
               notification(%Node{tag: "subject", attrs: %{"subject" => "New Subject"}}),
               credentials
             )

    assert subject.stub_type == :group_change_subject

    assert {:ok, description, {:groups_update, [%{description: "Description"}]}} =
             GroupNotification.decode(
               notification(%Node{
                 tag: "description",
                 content: [%Node{tag: "body", content: "Description"}]
               }),
               credentials
             )

    assert description.stub_type == :group_change_description

    assert {:ok, _announcement, {:groups_update, [%{announce?: true}]}} =
             GroupNotification.decode(notification(%Node{tag: "announcement"}), credentials)

    assert {:ok, ephemeral, {:groups_update, [%{ephemeral_duration: 3600}]}} =
             GroupNotification.decode(
               notification(%Node{tag: "ephemeral", attrs: %{"expiration" => "3600"}}),
               credentials
             )

    assert ephemeral.content.protocolMessage.ephemeralExpiration == 3600

    assert {:ok, restricted, {:groups_update, [%{restrict?: true}]}} =
             GroupNotification.decode(notification(%Node{tag: "locked"}), credentials)

    assert restricted.stub_type == :group_change_restrict

    assert {:ok, add_mode, {:groups_update, [%{member_add_mode?: true}]}} =
             GroupNotification.decode(
               notification(%Node{tag: "member_add_mode", content: "all_member_add"}),
               credentials
             )

    assert add_mode.stub_type == :group_member_add_mode
  end

  test "decodes invite, approval and join request lifecycle", %{credentials: credentials} do
    assert {:ok, _invite, {:groups_update, [%{invite_code: "fixture-code"}]}} =
             GroupNotification.decode(
               notification(%Node{tag: "invite", attrs: %{"code" => "fixture-code"}}),
               credentials
             )

    approval = %Node{
      tag: "membership_approval_mode",
      content: [%Node{tag: "group_join", attrs: %{"state" => "on"}}]
    }

    assert {:ok, _approval, {:groups_update, [%{join_approval_mode?: true}]}} =
             GroupNotification.decode(notification(approval), credentials)

    request = %Node{
      tag: "created_membership_requests",
      attrs: %{"request_method" => "invite_link"},
      content: [
        %Node{
          tag: "participant",
          attrs: %{"jid" => "requester@lid", "phone_number" => "requester@s.whatsapp.net"}
        }
      ]
    }

    assert {:ok, envelope, {:group_join_request, request}} =
             GroupNotification.decode(notification(request), credentials)

    assert envelope.stub_type == :group_membership_join_request
    assert request.action == :created
    assert request.method == :invite_link
  end

  test "projects group effects into typed public events" do
    state = %{subscribers: %{self() => make_ref()}}

    update = %{
      id: "fixture-group@g.us",
      author: "actor@lid",
      author_pn: "actor@s.whatsapp.net",
      author_username: nil,
      participants: [
        %{
          id: "member@lid",
          phone_number: "member@s.whatsapp.net",
          lid: "member@lid",
          username: nil,
          admin: :admin
        }
      ],
      action: :add
    }

    assert {:noreply, ^state} =
             Client.handle_info(
               {:connection_event, {:group_effect, {:group_participants_update, update}}},
               state
             )

    assert_receive {:baileys, _client,
                    {:group_participants_update,
                     %Baileys.GroupParticipantsUpdate{
                       id: "fixture-group@g.us",
                       participants: [%Baileys.GroupParticipant{admin: :admin}],
                       action: :add
                     }}}
  end

  defp notification(operation) do
    %Node{
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
      content: [operation]
    }
  end
end
