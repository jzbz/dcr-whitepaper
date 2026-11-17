#!/usr/bin/env bash
#
# Build the Decred whitepaper PDF with Typst.
#
#   ./build.sh            the whole paper  -> decred-whitepaper.pdf
#   ./build.sh 08         one chapter      -> ch08.pdf   (file-name prefix: 01..19, A1..A3)
#   ./build.sh -o out.pdf [chapter]        write to a specific file
#   ./build.sh -w [chapter]                rebuild on every change (typst watch)
#
# Output goes outside the source tree. The directory is, in order:
#   $WHITEPAPER_OUT, if set;
#   ../../artifacts/dcr-whitepaper/build, if ../../artifacts exists;
#   ./build otherwise.
#
# Needs typst (written against 0.15) and nothing else: the fonts are in fonts/
# or built into typst, system fonts are ignored, and the paper uses no
# external packages, so the build works offline and is the same everywhere.

set -euo pipefail

usage() {
	sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

out=""
mode="compile"
while getopts ":o:wh" opt; do
	case "$opt" in
	o) out="$OPTARG" ;;
	w) mode="watch" ;;
	h) usage 0 ;;
	:) echo "build.sh: -$OPTARG needs an argument" >&2; usage 2 ;;
	*) echo "build.sh: unknown option -$OPTARG" >&2; usage 2 ;;
	esac
done
shift $((OPTIND - 1))
[ "$#" -le 1 ] || usage 2
only="${1:-}"

if ! command -v typst >/dev/null 2>&1; then
	echo "build.sh: typst is not installed or not on PATH" >&2
	exit 1
fi

# System fonts are ignored so the result depends only on fonts/ and the faces
# built into typst, not on what happens to be installed on the machine.
args=(--root "$repo" --font-path "$repo/fonts" --ignore-system-fonts)
name="decred-whitepaper.pdf"
if [ -n "$only" ]; then
	if ! compgen -G "$repo/chapters/$only-*.typ" >/dev/null; then
		echo "build.sh: no chapter file chapters/$only-*.typ" >&2
		exit 2
	fi
	args+=(--input "only=$only")
	name="ch$only.pdf"
fi

if [ -z "$out" ]; then
	if [ -n "${WHITEPAPER_OUT:-}" ]; then
		dir="$WHITEPAPER_OUT"
	elif [ -d "$repo/../../artifacts" ]; then
		dir="$(cd "$repo/../../artifacts" && pwd)/dcr-whitepaper/build"
	else
		dir="$repo/build"
	fi
	out="$dir/$name"
fi
mkdir -p "$(dirname "$out")"

echo "$(typst --version)"
echo "building $out"
if [ "$mode" = "watch" ]; then
	exec typst watch "${args[@]}" "$repo/main.typ" "$out"
fi

start=$SECONDS
typst compile "${args[@]}" "$repo/main.typ" "$out"
pages=""
if command -v pdfinfo >/dev/null 2>&1; then
	pages="$(pdfinfo "$out" 2>/dev/null | awk '/^Pages:/ {print $2 " pages, "}')"
fi
echo "done: ${pages}$(du -h "$out" | cut -f1), $((SECONDS - start))s"
