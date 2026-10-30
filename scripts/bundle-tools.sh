#!/bin/zsh
# Copies command-line tools (FFmpeg, cwebp) and every non-system library they link against into
# an app bundle, rewriting load paths so the copies run on Macs without Homebrew.
#
#   scripts/bundle-tools.sh build/Flipdial.app ffmpeg cwebp
set -euo pipefail

APP="$1"; shift
TOOLS=("${@:-ffmpeg cwebp}")
BIN="$APP/Contents/Resources/bin"
LIB="$APP/Contents/Resources/lib"
rm -rf "$BIN" "$LIB"
mkdir -p "$BIN" "$LIB"

typeset -A original   # bundled file -> where it was copied from
typeset -A copied     # library basename -> 1

# Resolves an install name (absolute, @rpath or @loader_path) as seen from the original file.
resolve() {
  local dep="$1" from="$2" name candidate
  case "$dep" in
    @loader_path/*) candidate="$(dirname "$from")/${dep#@loader_path/}" ;;
    @rpath/*)
      name="${dep#@rpath/}"
      for dir in "$(dirname "$from")" "$(dirname "$from")/../lib" /opt/homebrew/lib /usr/local/lib \
                 $(otool -l "$from" | awk '/LC_RPATH/{getline; getline; print $2}' | sed "s|@loader_path|$(dirname "$from")|"); do
        [[ -e "$dir/$name" ]] && { candidate="$dir/$name"; break; }
      done ;;
    *) candidate="$dep" ;;
  esac
  [[ -n "${candidate:-}" && -e "$candidate" ]] || { echo "cannot resolve $dep (from $from)" >&2; return 1; }
  readlink -f "$candidate"
}

queue=()
for tool in ${=TOOLS}; do
  source="$(command -v "$tool" || true)"
  [[ -n "$source" ]] || { echo "$tool not found — install it with Homebrew (brew install ffmpeg webp)" >&2; exit 1; }
  source="$(readlink -f "$source")"
  cp "$source" "$BIN/$tool"
  chmod u+w "$BIN/$tool"
  original[$BIN/$tool]="$source"
  queue+=("$BIN/$tool")
done

while (( ${#queue} )); do
  file="${queue[1]}"; queue=("${queue[@]:1}")
  from="${original[$file]}"
  own_id="$(otool -D "$file" | tail -n +2)"
  for dep in $(otool -L "$file" | tail -n +2 | awk '{print $1}'); do
    [[ "$dep" == "$own_id" ]] && continue
    [[ "$dep" == /usr/lib/* || "$dep" == /System/* ]] && continue
    real="$(resolve "$dep" "$from")"
    base="$(basename "$dep")"
    if [[ -z "${copied[$base]:-}" ]]; then
      cp "$real" "$LIB/$base"
      chmod u+w "$LIB/$base"
      install_name_tool -id "@rpath/$base" "$LIB/$base" 2>/dev/null
      copied[$base]=1
      original[$LIB/$base]="$real"
      queue+=("$LIB/$base")
    fi
    if [[ "$file" == "$BIN"/* ]]; then
      install_name_tool -change "$dep" "@loader_path/../lib/$base" "$file" 2>/dev/null
    else
      install_name_tool -change "$dep" "@loader_path/$base" "$file" 2>/dev/null
    fi
  done
done

# install_name_tool invalidates signatures; re-sign every binary.
IDENTITY="${SIGN_IDENTITY:--}"
for f in "$LIB"/*.dylib "$BIN"/*; do
  codesign --force --sign "$IDENTITY" "$f" 2>/dev/null
done

echo "Bundled ${TOOLS[*]} with ${#copied} libraries ($(du -sh "$APP/Contents/Resources" | cut -f1))"
