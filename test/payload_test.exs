defmodule Baileys.Protocol.PayloadTest do
  use ExUnit.Case, async: true

  alias Baileys.Auth.Credentials
  alias Baileys.Protocol.Payload
  alias Baileys.Proto.ClientPayload.UserAgent.AppVersion

  @version [2, 3000, 1_043_857_760]

  test "uses the current WhatsApp Web version throughout registration" do
    payload = Payload.registration(Credentials.new())

    assert Payload.version() == @version

    assert payload.userAgent.appVersion == %AppVersion{
             primary: 2,
             secondary: 3000,
             tertiary: 1_043_857_760
           }

    assert payload.devicePairingData.buildHash ==
             :crypto.hash(:md5, Enum.join(@version, "."))
  end

  test "uses the current WhatsApp Web version for login" do
    credentials = %{Credentials.new() | me: %{id: "5511000000000:2@s.whatsapp.net"}}
    payload = Payload.login(credentials)

    assert payload.userAgent.appVersion == %AppVersion{
             primary: 2,
             secondary: 3000,
             tertiary: 1_043_857_760
           }
  end
end
