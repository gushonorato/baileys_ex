# Baileys

Minimal, OTP-native WhatsApp linked-device client for text messages.

The protocol implementation runs entirely on the BEAM. There is no Node.js,
JavaScript bridge, external process, Rustler or third-party native NIF. It uses
OTP `:crypto`/`:ssl` plus pure-Elixir libraries for WebSocket, protobuf and QR
rendering.

This project implements an unofficial WhatsApp Web protocol. It is not
affiliated with or endorsed by WhatsApp.

## Requirements

- Elixir 1.19 or later
- Erlang/OTP 28 or later

```sh
mix deps.get
```

## Callback Client

```elixir
defmodule MyWhatsApp do
  use Baileys

  def start_link(phone) do
    Baileys.start_link(__MODULE__, phone,
      name: __MODULE__,
      session: "primary",
      sessions_path: "./baileys_sessions"
    )
  end

  @impl Baileys
  def init(phone), do: {:ok, %{phone: phone}}

  @impl Baileys
  def handle_event(%Baileys.Event{type: :qr, data: qr}, state) do
    IO.inspect(qr.payload)
    {:noreply, state}
  end

  def handle_event(
        %Baileys.Event{client: client, type: :connection, data: %{state: :online}},
        state
      ) do
    Baileys.send_text(client, state.phone, "Hello World")
    {:noreply, state}
  end

  def handle_event(_event, state), do: {:noreply, state}
end
```

`Baileys` is the behaviour and `Baileys.start_link/3` follows the same
`module, init_arg, options` shape as `GenServer.start_link/3`. The event's
`client` field can be used for synchronous commands inside the callback without
calling the callback process itself.

Credentials, prekeys and Signal sessions are persisted under
`sessions_path/session/session.json` using a versioned schema and Base64 for
binary fields. Existing `session.etf` files are safely migrated on first load.
The directory and file modes are `0700` and `0600`. Do not run two clients
against the same session. Base64 is an encoding, not encryption; the JSON file
contains secrets and must not be shared or committed.

## QR Pairing

The executable example renders the QR directly in the terminal using a
pure-Elixir QR encoder.

## Pairing Code

Request a code after connecting:

```elixir
{:ok, code} =
  Baileys.request_pairing_code(client, "+5511999999999")

IO.puts(code)
```

A custom eight-character alphanumeric code is optional:

```elixir
Baileys.request_pairing_code(
  client,
  "+5511999999999",
  custom_code: "ABCD1234"
)
```

## Send Text

```elixir
{:ok, %Baileys.SentMessage{} = sent} =
  Baileys.send_text(client, "+5511999999999", "Hello world")

IO.inspect(sent.id)
```

`send_text/4` resolves PN/LID devices with USync, obtains missing prekey
bundles, advances one Signal ratchet per device, synchronizes other linked
devices and relays the encrypted stanza. Delivery and read state arrive as
separate `:message_status` events.

The complete example persists a `hello_world` session, waits for pairing and
sends `Hello world`:

```sh
mix run examples/hello_world.exs +5511999999999
```

## Event Types

```elixir
%Baileys.Event{client: client, type: :connection, data: %Baileys.Connection{}}
%Baileys.Event{client: client, type: :qr, data: %Baileys.QR{}}
%Baileys.Event{client: client, type: :paired, data: %Baileys.Account{}}
%Baileys.Event{client: client, type: :text_message, data: %Baileys.TextMessage{}}
%Baileys.Event{client: client, type: :message_status, data: %Baileys.MessageStatus{}}
%Baileys.Event{client: client, type: :disconnected, data: %Baileys.Disconnected{}}
%Baileys.Event{client: client, type: :error, data: %Baileys.Error{}}
```

Only direct text messages are in scope. Groups, media, newsletters, calls,
reactions and history synchronization are intentionally not exposed.

## Lifecycle

```elixir
Baileys.status(client)
Baileys.disconnect(client)
Baileys.connect(client)
Baileys.logout(client)
```

`logout/1` requires an active authenticated connection. After the server
removes the linked device, the local session is reset.

## Native Protocol

The implementation includes:

- Mint WebSocket over OTP TLS.
- Noise XX with X25519, AES-256-GCM and SHA-256.
- WhatsApp BinaryNode codec and complete token dictionaries.
- Minimal generated WhatsApp protobuf schema.
- XEd25519 signatures implemented in Elixir.
- Signal X3DH and Double Ratchet for direct messages.
- USync device/LID discovery and multi-device fanout.
- Atomic JSON session persistence with safe legacy ETF migration.

## Verification

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
```
