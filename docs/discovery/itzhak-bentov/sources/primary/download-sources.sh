#!/usr/bin/env bash
# Rehydrate the primary-source PDFs for the Itzhak Bentov discovery archive.
#
# The PDFs (~33 MB) are intentionally NOT committed: every one is a freely
# re-downloadable public-domain government document or published patent. This
# script re-fetches them into this directory. See MANIFEST.md for provenance.
#
# Usage:  bash download-sources.sh
set -euo pipefail
cd "$(dirname "$0")"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

fetch () { # $1=url  $2=out
  echo "  -> $2"
  curl -fsSL -A "$UA" -o "$2" "$1" || { echo "     FAILED: $1"; return 0; }
  case "$(file -b "$2" | cut -c1-3)" in PDF|Uni|ASC|UTF) ;; *) echo "     WARN: $2 not a PDF/text";; esac
}

echo "Patents (Google Patents official PDF store):"
PATENTS="US2766160 US3021573 US3051678 US3102540 US3119283 US3157178 US3165826 \
US3167602 US3313240 US3394540 US3474791 US3491756 US3579858 US3605725A US4168709 \
US4320762 US5356368A"
for P in $PATENTS; do
  LINK=$(curl -fsSL -A "$UA" "https://patents.google.com/patent/$P/en" \
         | grep -oE 'https://patentimages.storage.googleapis.com/[^"]+\.pdf' | head -1 || true)
  [ -n "${LINK:-}" ] && fetch "$LINK" "patent-$P.pdf" || echo "  -> patent-$P.pdf: NO LINK FOUND"
done

echo "Gateway Process report (Internet Archive mirror of CIA STARGATE doc):"
IA="https://ia800508.us.archive.org/32/items/1983-analysis-and-assessment-of-gateway-process"
enc () { python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$1"; }
fetch "$IA/$(enc '1 Analysis and Assessment of Gateway Process.pdf')"        "gateway-process-report.pdf"
fetch "$IA/$(enc '3 Analysis and Assessment of Gateway Process(CIA).pdf')"   "gateway-process-CIA-original-scan.pdf"
fetch "$IA/$(enc '2 Analysis and Assessment of Gateway Process P.25.pdf')"   "gateway-process-recovered-page25.pdf"
fetch "$IA/$(enc '1 Analysis and Assessment of Gateway Process_djvu.txt')"   "gateway-process-report-fulltext.txt"

echo "NTSB Flight 191 accident report:"
fetch "https://www.ntsb.gov/investigations/AccidentReports/Reports/AAR7917.pdf" "NTSB-AAR7917-flight191.pdf"

echo "Done. See MANIFEST.md for what each file substantiates."
