#!/usr/bin/env bash
# Render the four Reveal.js decks in presentations/ to PDF, one slide per page
# with every fragment revealed.
#
#   bash scripts/build_deck_pdfs.sh
#
# Uses DeckTape in a container: it drives a real browser through the deck, which
# is the only way to print Reveal.js faithfully — and it means nothing to install.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
docker info >/dev/null 2>&1 || { echo "ERROR: Docker is not running" >&2; exit 1; }

for html in presentations/*_presentation.html; do
    pdf="${html%.html}.pdf"
    printf "==> %s\n" "$(basename "$pdf")"
    docker run --rm -v "$PWD/presentations:/slides" astefanutti/decktape:latest \
        reveal --size 1600x900 --load-pause 1500 \
        "/slides/$(basename "$html")" "/slides/$(basename "$pdf")" 2>&1 \
        | grep -E "^Printed|Error|error" || true
done
echo
ls -la presentations/*.pdf
