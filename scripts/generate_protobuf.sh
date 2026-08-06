#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXPECTED_PROTOC="libprotoc 32.0"
ACTUAL_PROTOC=$(protoc --version)

if [ "$ACTUAL_PROTOC" != "$EXPECTED_PROTOC" ]; then
  printf 'expected %s, got %s\n' "$EXPECTED_PROTOC" "$ACTUAL_PROTOC" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/baileys-proto.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

export WA_PROTO_SOURCE="$ROOT/proto/WAProto.proto"
export WA_PROTO_TARGET="$TMP_DIR/WAProto.proto"
elixir "$ROOT/scripts/normalize_wa_proto.exs"

PROTOBUF_DIR="$ROOT/deps/protobuf"
(
  cd "$PROTOBUF_DIR"
  MIX_ENV=prod mix escript.build
)
PROTOC_GEN_ELIXIR="$PROTOBUF_DIR/protoc-gen-elixir"

mkdir -p "$ROOT/lib/baileys/proto/generated"
protoc \
  -I "$TMP_DIR" \
  --plugin=protoc-gen-elixir="$PROTOC_GEN_ELIXIR" \
  --elixir_out=package_prefix=baileys:"$ROOT/lib/baileys/proto/generated" \
  "$TMP_DIR/WAProto.proto"

mix format "$ROOT/lib/baileys/proto/generated/baileys/proto/WAProto.pb.ex"
