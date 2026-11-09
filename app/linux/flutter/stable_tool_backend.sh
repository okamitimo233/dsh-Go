#!/usr/bin/env bash
# Runs Flutter's Linux assemble step without invalidating every native object.
#
# The stock tool_backend.sh copies the engine headers into
# linux/flutter/ephemeral on every build, even when their contents are
# unchanged. Ninja uses mtimes, so all app and plugin C++ sources are then
# recompiled after every Dart-only change. Remember the bytes of the previous
# headers and restore their mtime when nothing changed; a real SDK header change
# still gets a fresh mtime and triggers the necessary rebuild.
set -euo pipefail

flutter_root=$1
project_dir=$2
build_dir=$3
shift 3

"$flutter_root/packages/flutter_tools/bin/tool_backend.sh" "$@"

header_dir="$project_dir/linux/flutter/ephemeral/flutter_linux"
if [[ ! -d "$header_dir" ]]; then
  exit 0
fi

# One cache for all build modes: the ephemeral engine headers are shared too.
cache_dir="$project_dir/build/linux/flutter_engine_headers"
mkdir -p "$cache_dir"
for header in "$header_dir"/*.h; do
  [[ -e "$header" ]] || continue
  cached="$cache_dir/${header##*/}"
  if [[ -f "$cached" ]] && cmp -s -- "$header" "$cached"; then
    touch -r "$cached" "$header"
  else
    cp -p -- "$header" "$cached"
  fi
done
