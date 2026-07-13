# WhatsApp Protobuf Schema

`WAProto.proto` is vendored from WhiskeySockets/Baileys commit
`731cd6b5d1991a16d0c65072fd3107c43968e4a9` (`7.0.0-rc13`). The source schema
reports WhatsApp version `2.3000.1029496320` and is kept byte-for-byte identical
to `WAProto/WAProto.proto` at that commit.

The upstream project is MIT licensed. Its license is included as
`LICENSE.Baileys`.

Generate the Elixir modules with:

```sh
mix deps.get
mix proto.generate
```

Generation is pinned to `protoc 32.0` and `protoc-gen-elixir 0.17.0` (the
version locked by `mix.lock`). Protobuf 32 requires the first value of every
proto3 enum to be zero, while 23 upstream enums start at a non-zero value.
`scripts/normalize_wa_proto.exs` adds a uniquely named zero value to those enums
in a temporary copy used only for code generation. It does not change the
vendored source or any serialized field number.

Normal builds and tests use only files in this repository. They never read the
sibling Baileys checkout.
