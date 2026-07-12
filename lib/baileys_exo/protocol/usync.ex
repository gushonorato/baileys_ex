defmodule BaileysExo.Protocol.USync do
  @moduledoc false

  alias BaileysExo.Binary.{Node, NodeUtils}
  alias BaileysExo.JID

  def device_query(jids) do
    users =
      jids
      |> Enum.map(&normalize_user/1)
      |> Enum.uniq()
      |> Enum.map(fn jid -> %Node{tag: "user", attrs: %{"jid" => jid}, content: []} end)

    %Node{
      tag: "iq",
      attrs: %{"to" => "s.whatsapp.net", "type" => "get", "xmlns" => "usync"},
      content: [
        %Node{
          tag: "usync",
          attrs: %{
            "context" => "message",
            "mode" => "query",
            "sid" => Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
            "last" => "true",
            "index" => "0"
          },
          content: [
            %Node{
              tag: "query",
              content: [
                %Node{tag: "devices", attrs: %{"version" => "2"}},
                %Node{tag: "lid"}
              ]
            },
            %Node{tag: "list", content: users}
          ]
        }
      ]
    }
  end

  def parse_devices(reply, my_jid, my_lid \\ nil) do
    with %Node{} = usync <- NodeUtils.child(reply, "usync"),
         %Node{} = list <- NodeUtils.child(usync, "list") do
      entries =
        list.content
        |> List.wrap()
        |> Enum.filter(&match?(%Node{tag: "user"}, &1))
        |> Enum.map(&parse_user/1)

      mappings =
        for %{jid: pn, lid: lid} <- entries, is_binary(lid), into: %{}, do: {pn, lid}

      devices = extract_devices(entries, my_jid, my_lid)
      {:ok, devices, mappings}
    else
      _missing -> {:error, :invalid_usync_response}
    end
  end

  def bundle_query(jids) do
    users = Enum.map(jids, &%Node{tag: "user", attrs: %{"jid" => &1}})

    %Node{
      tag: "iq",
      attrs: %{"xmlns" => "encrypt", "type" => "get", "to" => "s.whatsapp.net"},
      content: [%Node{tag: "key", content: users}]
    }
  end

  def parse_bundles(reply) do
    with %Node{} = list <- NodeUtils.child(reply, "list") do
      list.content
      |> List.wrap()
      |> Enum.filter(&match?(%Node{tag: "user"}, &1))
      |> Enum.reject(&(not is_nil(NodeUtils.child(&1, "error"))))
      |> Map.new(fn user -> {user.attrs["jid"], parse_bundle(user)} end)
      |> then(&{:ok, &1})
    else
      _missing -> {:error, :invalid_bundle_response}
    end
  end

  defp parse_user(%Node{} = user) do
    devices_node = NodeUtils.child(user, "devices")
    device_list = devices_node && NodeUtils.child(devices_node, "device-list")

    devices =
      case device_list do
        %Node{content: children} when is_list(children) ->
          children
          |> Enum.filter(&match?(%Node{tag: "device"}, &1))
          |> Enum.map(fn device ->
            %{
              id: integer_attr(device, "id", 0),
              key_index: integer_attr(device, "key-index", nil)
            }
          end)

        _missing ->
          []
      end

    lid_node = NodeUtils.child(user, "lid")
    %{jid: user.attrs["jid"], lid: lid_node && lid_node.attrs["val"], devices: devices}
  end

  defp extract_devices(entries, my_jid, my_lid) do
    {:ok, me} = JID.decode(my_jid)
    my_lid_user = if my_lid, do: elem(JID.decode(my_lid), 1).user

    Enum.flat_map(entries, fn entry ->
      case JID.decode(entry.jid) do
        {:ok, decoded} ->
          Enum.flat_map(entry.devices, fn device ->
            own? = decoded.user in [me.user, my_lid_user] and device.id == (me.device || 0)
            addressable? = device.id == 0 or not is_nil(device.key_index)

            if not own? and addressable? do
              [
                %{
                  user: decoded.user,
                  device: device.id,
                  server: decoded.server,
                  jid: JID.encode(decoded.user, decoded.server, device.id)
                }
              ]
            else
              []
            end
          end)

        {:error, :invalid_jid} ->
          []
      end
    end)
  end

  defp parse_bundle(user) do
    signed = NodeUtils.child(user, "skey")
    pre_key = NodeUtils.child(user, "key")

    bundle = %{
      registration_id: decode_integer(child_content(user, "registration")),
      identity_key: wire_key(child_content(user, "identity")),
      signed_pre_key: parse_key(signed, true)
    }

    if pre_key, do: Map.put(bundle, :pre_key, parse_key(pre_key, false)), else: bundle
  end

  defp parse_key(node, signed?) do
    key = %{
      key_id: decode_integer(child_content(node, "id")),
      public: wire_key(child_content(node, "value"))
    }

    if signed?, do: Map.put(key, :signature, child_content(node, "signature")), else: key
  end

  defp child_content(node, tag) do
    case NodeUtils.child(node, tag) do
      %Node{content: content} when is_binary(content) -> content
      _missing -> nil
    end
  end

  defp wire_key(<<5, _::binary-size(32)>> = key), do: key
  defp wire_key(<<key::binary-size(32)>>), do: <<5, key::binary>>
  defp wire_key(nil), do: nil

  defp decode_integer(nil), do: nil
  defp decode_integer(binary), do: :binary.decode_unsigned(binary, :big)

  defp integer_attr(node, key, default) do
    case Integer.parse(node.attrs[key] || "") do
      {integer, ""} -> integer
      _invalid -> default
    end
  end

  defp normalize_user(jid) do
    case JID.decode(jid) do
      {:ok, decoded} -> JID.encode(decoded.user, decoded.server)
      {:error, :invalid_jid} -> jid
    end
  end
end
