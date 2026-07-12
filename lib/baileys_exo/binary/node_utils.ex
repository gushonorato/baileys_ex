defmodule BaileysExo.Binary.NodeUtils do
  @moduledoc false

  alias BaileysExo.Binary.Node

  def child(%Node{content: children}, tag) when is_list(children) do
    Enum.find(children, &match?(%Node{tag: ^tag}, &1))
  end

  def child(_node, _tag), do: nil

  def children(%Node{content: children}, tag) when is_list(children) do
    Enum.filter(children, &match?(%Node{tag: ^tag}, &1))
  end

  def children(_node, _tag), do: []
end
