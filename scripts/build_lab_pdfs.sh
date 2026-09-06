#!/usr/bin/env bash
# Render every lab (and the Playbook) in labs/ to PDF.
#
#   bash scripts/build_lab_pdfs.sh
#
# pandoc turns the markdown into HTML with labs/.pdf-style.css inlined, then
# WeasyPrint renders it. WeasyPrint runs in a container so there is nothing to
# install and the output is identical on any machine — the same reason the labs
# themselves run in Docker.
#
# (Headless Chrome produced outline/cockroachdb_4day.pdf, but it hangs on
# batches: one file succeeds and the next never exits.)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"

command -v pandoc >/dev/null || { echo "ERROR: pandoc not installed (brew install pandoc)" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: Docker is not running" >&2; exit 1; }

HTML_DIR="$(mktemp -d)"
trap 'rm -rf "$HTML_DIR"' EXIT

echo "==> markdown -> html (pandoc)"
for md in "$REPO"/labs/*.md; do
    b="$(basename "$md" .md)"
    # Title the PDF with the document's own first heading, not the filename.
    title="$(grep -m1 '^# ' "$md" | sed 's/^# *//')"
    [ -n "$title" ] || title="$b"
    pandoc "$md" --standalone --embed-resources --css "$REPO/labs/.pdf-style.css" \
        --from gfm --to html5 --metadata title="$title" -o "$HTML_DIR/$b.html"
done
echo "    $(ls "$HTML_DIR"/*.html | wc -l | tr -d ' ') files"

echo "==> html -> pdf (weasyprint, containerised)"
docker run --rm -v "$HTML_DIR:/html" -v "$REPO/labs:/out" python:3.12-slim bash -c '
  set -e
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq --no-install-recommends \
    libpango-1.0-0 libpangoft2-1.0-0 libharfbuzz0b libcairo2 libgdk-pixbuf-2.0-0 \
    fonts-dejavu fonts-liberation >/dev/null 2>&1
  pip install -q weasyprint >/dev/null 2>&1
  cd /html
  fail=0
  for f in *.html; do
    b="${f%.html}"
    if weasyprint "$f" "/out/$b.pdf" 2>/dev/null; then
      printf "    %-42s %s\n" "$b.pdf" "$(du -h "/out/$b.pdf" | cut -f1)"
    else
      printf "    %-42s FAILED\n" "$b.pdf"; fail=1
    fi
  done
  exit $fail
'
echo
echo "$(ls "$REPO"/labs/*.pdf | wc -l | tr -d ' ') PDFs in labs/"
