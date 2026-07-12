defmodule BaileysExo.Binary.Node do
  @moduledoc false

  @type content :: nil | binary() | {:text, String.t()} | [t()]
  @type t :: %__MODULE__{tag: String.t(), attrs: %{String.t() => String.t()}, content: content()}

  @enforce_keys [:tag]
  defstruct [:tag, :content, attrs: %{}]
end
