defmodule Baileys.Binary.CodecTest do
  use ExUnit.Case, async: true

  alias Baileys.Binary.{Codec, Node, TokenDictionary}

  test "contains the complete token dictionary snapshot" do
    assert length(TokenDictionary.single()) == 236
    assert Enum.map(TokenDictionary.double(), &length/1) == [256, 256, 256, 256]
  end

  test "round trips tokenized nodes, JIDs and children" do
    node = %Node{
      tag: "iq",
      attrs: %{
        "id" => "1234567890",
        "to" => "5511999999999@s.whatsapp.net",
        "type" => "get",
        "xmlns" => "urn:xmpp:ping"
      },
      content: [%Node{tag: "ping"}]
    }

    assert {:ok, ^node} = node |> Codec.encode() |> Codec.decode()
  end

  test "round trips raw binary content" do
    node = %Node{tag: "enc", attrs: %{"type" => "msg"}, content: <<0, 1, 2, 255>>}
    assert {:ok, ^node} = node |> Codec.encode() |> Codec.decode()
  end

  test "round trips binary content at the binary 20 boundary" do
    node = %Node{tag: "enc", content: :binary.copy(<<1>>, 256)}
    assert {:ok, ^node} = node |> Codec.encode() |> Codec.decode()
  end
end
