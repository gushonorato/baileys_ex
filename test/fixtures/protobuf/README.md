# Protobuf Fixtures

These fixtures contain synthetic message data and non-numeric fixture JIDs only.
No fixture was produced from a real WhatsApp account or session.

They exercise fields represented by the schema vendored from Baileys commit
`731cd6b5d1991a16d0c65072fd3107c43968e4a9`. Regenerate them after compiling the
schema with:

```sh
mix run scripts/generate_protobuf_fixtures.exs
```
