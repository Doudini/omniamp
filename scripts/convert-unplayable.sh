#!/bin/bash
# Converts music OmniAmp can't play (WMA, SHN, APE, WavPack, Musepack, TTA) to FLAC, next to the originals.
#
#   scripts/convert-unplayable.sh /Volumes/MUSIC-1            # list what would be converted (nothing is written)
#   scripts/convert-unplayable.sh --convert /Volumes/MUSIC-1  # convert
#
# FLAC is lossless, so a lossy WMA keeps exactly the quality it has (the files get bigger). Tags are copied.
# The originals stay: the library hides a WMA once a FLAC of the same name sits next to it. Delete or move
# them yourself once you're happy. Protected iTunes files (.m4p) can't be converted by anyone: they're listed.
#
# Needs ffmpeg:  brew install ffmpeg
# Afterwards, FOLDERS → Rescan All in the library (a network share doesn't report new files).
set -uo pipefail

convert=0
roots=()
for a in "$@"; do
    case "$a" in
        --convert) convert=1 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) roots+=("$a") ;;
    esac
done
[ ${#roots[@]} -gt 0 ] || { echo "usage: $0 [--convert] <music folder>…" >&2; exit 2; }
if [ $convert -eq 1 ] && ! command -v ffmpeg >/dev/null; then
    echo "ffmpeg is needed: brew install ffmpeg" >&2
    exit 1
fi

todo=0 done=0 skipped=0 failed=0 protected=0
while IFS= read -r -d '' f; do
    ext="${f##*.}"
    ext_lc="$(printf '%s' "$ext" | tr 'A-Z' 'a-z')"
    if [ "$ext_lc" = "m4p" ]; then
        protected=$((protected + 1))
        echo "protected (can't convert): $f"
        continue
    fi
    out="${f%.*}.flac"
    if [ -e "$out" ]; then skipped=$((skipped + 1)); continue; fi
    todo=$((todo + 1))
    if [ $convert -eq 0 ]; then echo "would convert: $f"; continue; fi
    echo "converting: $f"
    # Into a hidden temporary name first: a half-written file never looks finished to the library.
    tmp="$(dirname "$f")/.omniamp-converting-$$.flac"
    if ffmpeg -nostdin -hide_banner -loglevel error -y -i "$f" -map 0:a:0 -map_metadata 0 -c:a flac -compression_level 8 "$tmp" \
        && mv "$tmp" "$out"; then
        touch -r "$f" "$out" 2>/dev/null   # keep the original's date (for "Recently Added")
        done=$((done + 1))
    else
        rm -f "$tmp"
        failed=$((failed + 1))
        echo "  FAILED: $f" >&2
    fi
done < <(find "${roots[@]}" -type f \( -iname '*.wma' -o -iname '*.shn' -o -iname '*.ape' -o -iname '*.wv' -o -iname '*.mpc' \
                                     -o -iname '*.tta' -o -iname '*.m4p' \) ! -name '._*' -print0)

echo
if [ $convert -eq 1 ]; then
    echo "converted $done, failed $failed, already converted $skipped, protected $protected"
else
    echo "$todo to convert, $skipped already converted, $protected protected. Run again with --convert to convert them."
fi
