#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXPECTED_PROTOC="libprotoc 32.0"
ACTUAL_PROTOC=$(protoc --version)

if [ "$ACTUAL_PROTOC" != "$EXPECTED_PROTOC" ]; then
  printf 'expected %s, got %s\n' "$EXPECTED_PROTOC" "$ACTUAL_PROTOC" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/baileys-exo-proto.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

export WA_PROTO_SOURCE="$ROOT/proto/WAProto.proto"
export WA_PROTO_TARGET="$TMP_DIR/WAProto.proto"
elixir "$ROOT/scripts/normalize_wa_proto.exs"

mkdir -p "$ROOT/lib/baileys_exo/proto/generated"
protoc \
  -I "$TMP_DIR" \
  --plugin=protoc-gen-elixir="$ROOT/deps/protobuf/protoc-gen-elixir" \
  --elixir_out=package_prefix=baileys_exo:"$ROOT/lib/baileys_exo/proto/generated" \
  "$TMP_DIR/WAProto.proto"

mix format "$ROOT/lib/baileys_exo/proto/generated/baileys_exo/proto/WAProto.pb.ex"
