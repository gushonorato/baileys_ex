defmodule Baileys.Messages.GroupNotification do
  @moduledoc false

  alias Baileys.Auth.Credentials
  alias Baileys.Binary.{Node, NodeUtils}
  alias Baileys.Messages.Receiver
  alias Baileys.Proto.Message

  def decode(
        %Node{tag: "notification", attrs: %{"type" => "w:gp2"}} = node,
        %Credentials{} = credentials
      ) do
    with {:ok, context} <- Receiver.context(node, credentials),
         {:ok, content, stub_type, stub_parameters, effect} <- operation(node, context) do
      envelope = %{
        key: context.key,
        content: content,
        raw_content: nil,
        timestamp: context.timestamp,
        status: context.status,
        category: context.category,
        push_name: context.push_name,
        verified_business_name: nil,
        stub_type: stub_type,
        stub_parameters: stub_parameters,
        broadcast: false,
        offline: Map.has_key?(node.attrs, "offline"),
        retry_count: nil,
        chat_jid: context.chat_jid,
        sender_jid: context.sender_jid,
        signal_jid: context.signal_jid,
        wire_chat_jid: context.wire_chat_jid,
        wire_sender_jid: context.wire_sender_jid,
        protocol_response: nil,
        receipt_attrs: nil
      }

      {:ok, envelope, effect}
    end
  end

  def decode(_node, _credentials), do: {:error, :unsupported_group_notification}

  defp operation(node, context) do
    cond do
      operation = NodeUtils.child(node, "create") ->
        create(operation, context)

      operation = NodeUtils.child(node, "add") ->
        participants(operation, context, :add)

      operation = NodeUtils.child(node, "remove") ->
        participants(operation, context, :remove, remove_stub(operation, context))

      operation = NodeUtils.child(node, "leave") ->
        participants(operation, context, :remove, :leave)

      operation = NodeUtils.child(node, "modify") ->
        participants(operation, context, :modify)

      operation = NodeUtils.child(node, "promote") ->
        participants(operation, context, :promote)

      operation = NodeUtils.child(node, "demote") ->
        participants(operation, context, :demote)

      operation = NodeUtils.child(node, "subject") ->
        subject(operation, context)

      operation = NodeUtils.child(node, "description") ->
        description(operation, context)

      NodeUtils.child(node, "announcement") ->
        announcement(context, true)

      NodeUtils.child(node, "not_announcement") ->
        announcement(context, false)

      NodeUtils.child(node, "locked") ->
        restriction(context, true)

      NodeUtils.child(node, "unlocked") ->
        restriction(context, false)

      operation = NodeUtils.child(node, "ephemeral") ->
        ephemeral(context, integer(operation.attrs["expiration"], 0))

      NodeUtils.child(node, "not_ephemeral") ->
        ephemeral(context, 0)

      operation = NodeUtils.child(node, "invite") ->
        invite(operation, context)

      operation = NodeUtils.child(node, "membership_approval_mode") ->
        approval(operation, context)

      operation = NodeUtils.child(node, "member_add_mode") ->
        member_add_mode(operation, context)

      operation = NodeUtils.child(node, "created_membership_requests") ->
        join_request(operation, context, :created)

      operation = NodeUtils.child(node, "revoked_membership_requests") ->
        join_request(operation, context, :revoked)

      true ->
        {:error, :unsupported_group_notification}
    end
  end

  defp create(operation, context) do
    with %Node{} = group <- NodeUtils.child(operation, "group"),
         id when is_binary(id) <- group.attrs["id"] do
      metadata = %{
        id: group_jid(id),
        subject: group.attrs["subject"],
        addressing_mode: addressing_mode(group.attrs["addressing_mode"]),
        owner: group.attrs["creator"] || group.attrs["s_o"],
        owner_pn: group.attrs["creator_pn"] || group.attrs["s_o_pn"],
        owner_username: group.attrs["creator_username"] || group.attrs["s_o_username"],
        creation: unix_time(group.attrs["creation"]),
        description: description_body(NodeUtils.child(group, "description")),
        size: integer(group.attrs["size"], nil),
        announce?: not is_nil(NodeUtils.child(group, "announcement")),
        restrict?: not is_nil(NodeUtils.child(group, "locked")),
        join_approval_mode?:
          approval_enabled?(NodeUtils.child(group, "membership_approval_mode")),
        ephemeral_duration: ephemeral_duration(group),
        author: context.wire_sender_jid,
        author_pn: context.key.participant_alt,
        author_username: context.key.participant_username,
        participants: Enum.map(NodeUtils.children(group, "participant"), &participant/1)
      }

      {:ok, nil, :group_create, List.wrap(metadata.subject), {:groups_upsert, [metadata]}}
    else
      _invalid -> {:error, :invalid_group_create}
    end
  end

  defp participants(operation, context, action, stub_action \\ nil) do
    participants = Enum.map(NodeUtils.children(operation, "participant"), &participant/1)

    if participants == [] do
      {:error, :missing_group_participants}
    else
      update = %{
        id: context.wire_chat_jid,
        author: context.wire_sender_jid,
        author_pn: context.key.participant_alt,
        author_username: context.key.participant_username,
        participants: participants,
        action: action
      }

      {:ok, nil, participant_stub(stub_action || action), participants,
       {:group_participants_update, update}}
    end
  end

  defp remove_stub(operation, context) do
    case NodeUtils.children(operation, "participant") do
      [%Node{attrs: %{"jid" => jid}}] ->
        if same_account?(jid, context.wire_sender_jid) or
             same_account?(jid, context.key.participant_alt),
           do: :leave,
           else: :remove

      _participants ->
        :remove
    end
  end

  defp same_account?(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, left} <- Baileys.JID.decode(left),
         {:ok, right} <- Baileys.JID.decode(right) do
      left.user == right.user and left.server == right.server
    else
      _invalid -> left == right
    end
  end

  defp same_account?(_left, _right), do: false

  defp subject(operation, context) do
    value = operation.attrs["subject"]
    update = group_update(context, %{subject: value})
    {:ok, nil, :group_change_subject, List.wrap(value), {:groups_update, [update]}}
  end

  defp description(operation, context) do
    value = description_body(operation)
    update = group_update(context, %{description: value})
    {:ok, nil, :group_change_description, List.wrap(value), {:groups_update, [update]}}
  end

  defp announcement(context, enabled) do
    update = group_update(context, %{announce?: enabled})
    value = if enabled, do: "on", else: "off"
    {:ok, nil, :group_change_announce, [value], {:groups_update, [update]}}
  end

  defp restriction(context, enabled) do
    update = group_update(context, %{restrict?: enabled})
    value = if enabled, do: "on", else: "off"
    {:ok, nil, :group_change_restrict, [value], {:groups_update, [update]}}
  end

  defp ephemeral(context, expiration) do
    content = %Message{
      protocolMessage: %Message.ProtocolMessage{
        type: :EPHEMERAL_SETTING,
        ephemeralExpiration: expiration
      }
    }

    update = group_update(context, %{ephemeral_duration: expiration})
    {:ok, content, nil, [], {:groups_update, [update]}}
  end

  defp invite(operation, context) do
    code = operation.attrs["code"]
    update = group_update(context, %{invite_code: code})
    {:ok, nil, :group_change_invite_link, List.wrap(code), {:groups_update, [update]}}
  end

  defp approval(operation, context) do
    enabled = approval_enabled?(operation)
    update = group_update(context, %{join_approval_mode?: enabled})
    value = if enabled, do: "on", else: "off"
    {:ok, nil, :group_membership_join_approval_mode, [value], {:groups_update, [update]}}
  end

  defp member_add_mode(operation, context) do
    value = text_content(operation)
    enabled = value == "all_member_add"
    update = group_update(context, %{member_add_mode?: enabled})
    {:ok, nil, :group_member_add_mode, List.wrap(value), {:groups_update, [update]}}
  end

  defp join_request(operation, context, requested_action) do
    with %Node{} = participant <- NodeUtils.child(operation, "participant"),
         id when is_binary(id) <- participant.attrs["jid"] do
      action =
        if requested_action == :revoked and not same_user?(id, context.wire_sender_jid),
          do: :rejected,
          else: requested_action

      update = %{
        id: context.wire_chat_jid,
        author: context.wire_sender_jid,
        author_pn: context.key.participant_alt,
        author_username: context.key.participant_username,
        participant: id,
        participant_pn: participant.attrs["phone_number"],
        action: action,
        method: join_method(operation.attrs["request_method"])
      }

      {:ok, nil, :group_membership_join_request, [update], {:group_join_request, update}}
    else
      _invalid -> {:error, :invalid_group_join_request}
    end
  end

  defp participant(%Node{attrs: attrs}) do
    id = attrs["jid"]
    lid? = is_binary(id) and String.ends_with?(id, "@lid")

    %{
      id: id,
      phone_number: if(lid?, do: attrs["phone_number"]),
      lid: if(lid?, do: id, else: attrs["lid"]),
      username: attrs["participant_username"] || attrs["username"],
      admin: admin(attrs["type"])
    }
  end

  defp group_update(context, changes) do
    Map.merge(
      %{
        id: context.wire_chat_jid,
        author: context.wire_sender_jid,
        author_pn: context.key.participant_alt,
        author_username: context.key.participant_username
      },
      changes
    )
  end

  defp description_body(nil), do: nil

  defp description_body(node) do
    case NodeUtils.child(node, "body") do
      %Node{content: content} when is_binary(content) -> content
      %Node{content: {:text, content}} -> content
      _missing -> nil
    end
  end

  defp text_content(%Node{content: content}) when is_binary(content), do: content
  defp text_content(%Node{content: {:text, content}}) when is_binary(content), do: content
  defp text_content(_node), do: nil

  defp approval_enabled?(nil), do: nil

  defp approval_enabled?(node) do
    case NodeUtils.child(node, "group_join") do
      %Node{attrs: %{"state" => "on"}} -> true
      %Node{} -> false
      nil -> nil
    end
  end

  defp ephemeral_duration(group) do
    case NodeUtils.child(group, "ephemeral") do
      %Node{attrs: attrs} -> integer(attrs["expiration"], nil)
      nil -> nil
    end
  end

  defp participant_stub(:add), do: :group_participant_add
  defp participant_stub(:remove), do: :group_participant_remove
  defp participant_stub(:leave), do: :group_participant_leave
  defp participant_stub(:modify), do: :group_participant_change_number
  defp participant_stub(:promote), do: :group_participant_promote
  defp participant_stub(:demote), do: :group_participant_demote

  defp admin("admin"), do: :admin
  defp admin("superadmin"), do: :superadmin
  defp admin(_type), do: nil

  defp addressing_mode("lid"), do: :lid
  defp addressing_mode("pn"), do: :pn
  defp addressing_mode(_mode), do: nil

  defp join_method("invite_link"), do: :invite_link
  defp join_method("linked_group_join"), do: :linked_group_join
  defp join_method("non_admin_add"), do: :non_admin_add
  defp join_method(_method), do: nil

  defp integer(value, default) do
    case Integer.parse(value || "") do
      {integer, ""} -> integer
      _invalid -> default
    end
  end

  defp unix_time(value) do
    case integer(value, nil) do
      nil ->
        nil

      timestamp ->
        case DateTime.from_unix(timestamp) do
          {:ok, datetime} -> datetime
          _ -> nil
        end
    end
  end

  defp same_user?(left, right) do
    with [left | _] <- String.split(left || "", ["@", ":"], parts: 2),
         [right | _] <- String.split(right || "", ["@", ":"], parts: 2) do
      left == right
    else
      _invalid -> false
    end
  end

  defp group_jid(id) do
    if String.contains?(id, "@"), do: id, else: id <> "@g.us"
  end
end
