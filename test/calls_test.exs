defmodule Baileys.CallsTest do
  use ExUnit.Case, async: true

  alias Baileys.Binary.Node
  alias Baileys.Calls

  test "maps call lifecycle statuses and relay latency" do
    for {child, status} <- [
          {%Node{tag: "ringing"}, :ringing},
          {%Node{tag: "preaccept"}, :preaccept},
          {%Node{tag: "transport"}, :transport},
          {%Node{tag: "relaylatency", attrs: %{"latency_ms" => "42"}}, :relay_latency},
          {%Node{tag: "reject"}, :reject},
          {%Node{tag: "accept"}, :accept},
          {%Node{tag: "terminate"}, :terminate},
          {%Node{tag: "terminate", attrs: %{"reason" => "timeout"}}, :timeout}
        ] do
      child = put_in(child.attrs["call-id"], "fixture-call")
      child = put_in(child.attrs["from"], "caller@s.whatsapp.net")

      assert {:ok, call} = Calls.decode(call_node(child), fn -> ~U[2000-01-01 00:00:00Z] end)
      assert call.status == status
      assert call.id == "fixture-call"
      assert call.chat_id == "caller@s.whatsapp.net"
      assert call.date == ~U[2023-11-14 22:13:20Z]

      if status == :relay_latency, do: assert(call.latency_ms == 42)
    end
  end

  test "extracts complete offer metadata" do
    offer = %Node{
      tag: "offer",
      attrs: %{
        "call-id" => "group-call",
        "call-creator" => "caller@lid",
        "caller_pn" => "caller@s.whatsapp.net",
        "type" => "group",
        "group-jid" => "fixture-group@g.us"
      },
      content: [%Node{tag: "video"}]
    }

    assert {:ok, call} = Calls.decode(call_node(offer))
    assert call.status == :offer
    assert call.from == "caller@lid"
    assert call.caller_pn == "caller@s.whatsapp.net"
    assert call.is_video?
    assert call.is_group?
    assert call.group_jid == "fixture-group@g.us"
  end

  test "rejects unknown and malformed call children" do
    assert {:error, :missing_call_info} = Calls.decode(call_node(nil))
    assert {:error, :unsupported_call_status} = Calls.decode(call_node(%Node{tag: "future"}))
  end

  defp call_node(child) do
    %Node{
      tag: "call",
      attrs: %{
        "id" => "call-stanza",
        "from" => "caller@s.whatsapp.net",
        "t" => "1700000000"
      },
      content: List.wrap(child)
    }
  end
end
