#!/bin/zsh
# merge-duplex — merge two-pass ADF scans into one clean, searchable PDF.

# --- Defaults (override with flags; run with -h for help) ---
COLOR_MODE=auto     # auto | bw | gray | color  (auto never converts to b&w)
BACK_ROTATE=0       # 0 | 180 | auto — rotate all backs (auto guesses; can be wrong)
LEVEL="15%,85%,0.8" # gray/color contrast: black point, white point, gamma (<1 = darker)
THRESHOLD="65%"     # b&w: overall darkness cutoff — higher = darker
LOCAL=8             # b&w: local sensitivity % for faint strokes — lower = picks up fainter marks
BOLD=0              # b&w: 1 = thicken text and lines by one pixel
DPI=""              # blank = auto-detect
EDGE=0.08           # inches of page edge to whiten (removes scanner shadows)
KEEP_BLANKS=0
OCR=1               # invisible text layer only — pages are never rotated or altered
OCR_LANG=eng
REVERSE=1           # backs come out of the feeder in reverse order
ENHANCE=1           # sharpening for gray/color
OPEN=0
FORCE=0

DEFAULT_DPI=300
COLOR_MIN=0.005     # auto mode: fraction of colored pixels to count as color
BLANK_MAX=0.0005    # back pages with less ink than this fraction are treated as blank

usage() {
  cat <<EOF
Usage: ${0:t} [options] fronts.pdf backs.pdf [output.pdf]

Merges fronts and backs into one PDF (front 1, back 1, front 2, back 2...),
straightens pages, cleans edges, boosts contrast, removes blank backs, and
adds searchable text. Output defaults to <fronts>-merged.pdf.

Options:
  -m MODE    auto | bw | gray | color        (default: $COLOR_MODE)
             auto keeps gray scans gray; use bw for smaller print-only files
  -t PCT     b&w darkness cutoff             (default: $THRESHOLD; darker: 75%)
  -L PCT     b&w faint-stroke sensitivity    (default: $LOCAL; fainter: 5, cleaner: 12)
  -b         b&w: bold — thicken text and lines
  -c LEVEL   gray/color contrast             (default: $LEVEL; darker: 20%,85%,0.7)
  -u MODE    rotate all backs: 0 | 180 | auto (default: $BACK_ROTATE)
  -d DPI     override detected scan DPI
  -e INCHES  edge margin to whiten, 0 = off  (default: $EDGE)
  -k         keep blank pages
  -r         backs are in normal order (not reversed)
  -E         no sharpening
  -n         no OCR (skip searchable text)
  -l LANG    OCR language(s), e.g. eng+fra   (default: $OCR_LANG)
  -o         open the result when done
  -f         overwrite output if it exists
  -h         show this help
EOF
}

while getopts "m:t:L:bc:u:d:e:krEnl:ofh" opt; do
  case $opt in
    m) COLOR_MODE=$OPTARG ;;
    t) THRESHOLD=$OPTARG ;;
    L) LOCAL=${OPTARG%\%} ;;
    b) BOLD=1 ;;
    c) LEVEL=$OPTARG ;;
    u) BACK_ROTATE=$OPTARG ;;
    d) DPI=$OPTARG ;;
    e) EDGE=$OPTARG ;;
    k) KEEP_BLANKS=1 ;;
    r) REVERSE=0 ;;
    E) ENHANCE=0 ;;
    n) OCR=0 ;;
    l) OCR_LANG=$OPTARG ;;
    o) OPEN=1 ;;
    f) FORCE=1 ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

set -e

if [[ $# -lt 2 || $# -gt 3 ]]; then usage >&2; exit 1; fi

fronts="${1:A}" backs="${2:A}"
out="${3:-${1:r}-merged.pdf}"; out="${out:A}"

for f in "$fronts" "$backs"; do
  [[ -f "$f" ]] || { echo "Not found: $f" >&2; exit 1; }
done
if [[ "$out" == "$fronts" || "$out" == "$backs" ]]; then
  echo "Output can't be one of the input files" >&2; exit 1
fi
if [[ -e "$out" && $FORCE == 0 ]]; then
  echo "Output exists: $out (use -f to overwrite)" >&2; exit 1
fi

for cmd in magick gs pdfimages pdfinfo; do
  command -v $cmd >/dev/null || { echo "Missing $cmd — run: brew install imagemagick ghostscript poppler" >&2; exit 1; }
done
if (( OCR )); then
  for cmd in tesseract qpdf; do
    if ! command -v $cmd >/dev/null; then
      echo "Note: $cmd not found — skipping OCR (brew install tesseract qpdf)"
      OCR=0
    fi
  done
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
merged="$tmp/merged.pdf"
cleaned="$tmp/cleaned.pdf"

# --- 1. Decide whether to rotate the backs ---
echo "[1/6] Back-page orientation..."
rotate_backs=0
case $BACK_ROTATE in
  0)   echo "      Leaving as scanned" ;;
  180) rotate_backs=1; echo "      Rotating backs 180°" ;;
  auto)
    if command -v tesseract >/dev/null; then
      nb=$(pdfinfo "$backs" | awk '/^Pages:/ {print $2}')
      for p in $(( nb / 2 )) 0 $(( nb - 1 )); do   # try a few pages in case one is blank
        magick -density 150 "${backs}[$p]" -colorspace Gray "$tmp/osd.png" 2>/dev/null || continue
        r=$(tesseract "$tmp/osd.png" - --psm 0 2>/dev/null | awk '/^Rotate:/ {print $2}')
        if [[ -n $r ]]; then
          if [[ $r == 180 ]]; then rotate_backs=1; fi
          break
        fi
      done
      if (( rotate_backs )); then echo "      Detected upside-down backs — rotating"; else echo "      Backs look upright"; fi
    else
      echo "      tesseract not found — leaving as scanned"
    fi
    ;;
  *) echo "Unknown -u value: $BACK_ROTATE (use 0, 180, or auto)" >&2; exit 1 ;;
esac

# --- 2. Merge (prints the merged indices of back pages) ---
echo "[2/6] Merging pages..."
back_idx=( $(osascript -l JavaScript - "$fronts" "$backs" "$merged" "$REVERSE" "$rotate_backs" <<'EOF'
ObjC.import('Foundation');
ObjC.import('PDFKit');

function run(argv) {
  const [frontsPath, backsPath, outPath, rev, rot] = argv;
  const reverse = rev === '1', rotate = rot === '1';
  const open = p => $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(p));

  const f = open(frontsPath), b = open(backsPath);
  if (f.isNil() || b.isNil()) throw new Error('Could not open one of the PDFs');

  const n = f.pageCount, m = b.pageCount;
  if (n !== m) console.log(`      Warning: ${n} front pages vs ${m} back pages`);

  const out = $.PDFDocument.alloc.init;
  const backs = [];
  let idx = 0;
  for (let i = 0; i < Math.max(n, m); i++) {
    if (i < n) out.insertPageAtIndex(f.pageAtIndex(i).copy, idx++);
    if (i < m) {
      const page = b.pageAtIndex(reverse ? m - 1 - i : i).copy;
      if (rotate) page.setRotation((page.rotation + 180) % 360);
      out.insertPageAtIndex(page, idx);
      backs.push(idx++);
    }
  }

  if (!out.writeToFile(outPath)) throw new Error('Failed to write ' + outPath);
  console.log(`      ${idx} pages merged`);
  return backs.join(' ');
}
EOF
) )

# --- 3. Detect DPI and bit depth, find blank backs ---
echo "[3/6] Analyzing pages..."
detected_dpi="" bpc=""
read detected_dpi bpc <<< "$(pdfimages -list "$fronts" 2>/dev/null |
  awk 'NR>2 && $13+0>0 {printf "%d %s", $13+0.5, $8; exit}')" || true

if [[ -z "$DPI" ]]; then
  if [[ -n "$detected_dpi" ]]; then
    DPI=$detected_dpi
    echo "      Detected $DPI DPI"
  else
    DPI=$DEFAULT_DPI
    echo "      Couldn't detect DPI, using $DPI"
  fi
fi

# ink coverage per page: anything darker than 75% gray counts, ignoring the outer 8%
ink=( ${(f)"$(magick -density 100 "$merged" -colorspace Gray -shave 8%x8% \
  -threshold 75% -negate -format "%[fx:mean]\n" info:)"} )

keep=() blanks=()
for i in {1..${#ink}}; do
  idx=$((i - 1))
  if (( ! KEEP_BLANKS && ${back_idx[(Ie)$idx]} && ink[i] < BLANK_MAX )); then
    blanks+=$i
    printf "      Page %d looks blank (ink=%.5f) — removing\n" $i ${ink[i]}
  else
    keep+=$idx
  fi
done

# --- 4. Pick mode: b&w only if the scan already is; never convert gray to b&w ---
mode=$COLOR_MODE
if [[ $mode == auto ]]; then
  if [[ $bpc == 1 ]]; then
    mode=bw
    echo "      Scan is 1-bit black & white"
  else
    sample="${merged}[${keep[1]}]"
    colored=$(magick -density 100 "$sample" -colorspace HCL -channel G -separate +channel \
      -threshold 15% -format "%[fx:mean]" info:)
    if (( colored > COLOR_MIN )); then
      mode=color
      printf "      Color content found (%.2f%% of page)\n" $(( colored * 100 ))
    else
      mode=gray
      printf "      No color content (%.2f%% of page) — keeping grayscale\n" $(( colored * 100 ))
    fi
  fi
fi
echo "[4/6] Processing as: $mode"

# --- 5. Straighten, clean edges, contrast ---
echo "[5/6] Enhancing ${#keep} page(s)..."
edge_px=$(printf "%.0f" $(( DPI * EDGE )))
common=(-background white -deskew 40% +repage)
if (( edge_px > 0 )); then
  common+=(-shave ${edge_px}x${edge_px} -bordercolor white -border ${edge_px}x${edge_px})
fi

case $mode in
  bw)
    # Two passes per page, combined: a pixel is black if either says so.
    #   global: darker than THRESHOLD           — solid print, lines, filled areas
    #   local:  darker than the paper around it — faint pen and pencil strokes
    win=$(( DPI / 10 ))                       # ~2.5 mm neighborhood
    bold_opts=()
    if (( BOLD )); then bold_opts=(-morphology Erode Disk:1); fi   # grows black by 1px
    n=0
    for p in $keep; do
      n=$((n + 1))
      printf "\r      page %d/%d" $n ${#keep}
      magick -density "$DPI" "${merged}[$p]" -colorspace Gray "${common[@]}" -blur 0x0.5 \
        \( -clone 0 -threshold "$THRESHOLD" \) \
        \( -clone 0 -lat ${win}x${win}-${LOCAL}% \) \
        -delete 0 -compose Multiply -composite "${bold_opts[@]}" \
        -type bilevel -units PixelsPerInch -density "$DPI" \
        "$tmp/p$(printf %04d $n).tif"
    done
    echo
    magick "$tmp"/p*.tif -units PixelsPerInch -density "$DPI" -compress Group4 "$cleaned"
    ;;
  gray|color)
    opts=("${common[@]}" -level "$LEVEL")
    if [[ $mode == gray ]]; then opts=(-colorspace Gray "${opts[@]}"); fi
    if (( ENHANCE )); then opts+=(-unsharp 0x1+0.6+0.02); fi
    magick -density "$DPI" "${merged}[${(j:,:)keep}]" "${opts[@]}" \
      -compress jpeg -quality 85 -units PixelsPerInch -density "$DPI" "$cleaned"
    ;;
  *) echo "Unknown mode: $mode (use auto, bw, gray, or color)" >&2; exit 1 ;;
esac

# --- 6. OCR: build an invisible text layer and lay it over the untouched pages ---
# Pages are never passed through OCR for output, so their orientation can't change.
layout() {   # page sizes and rotations, used to verify nothing moved
  local np=$(pdfinfo "$1" 2>/dev/null | awk '/^Pages:/ {print $2}')
  pdfinfo -f 1 -l "$np" "$1" 2>/dev/null | awk '/^Page +[0-9]+ (size|rot):/'
}

final="$cleaned"
if (( OCR )); then
  echo "[6/6] Adding searchable text ($OCR_LANG)..."
  np=$(pdfinfo "$cleaned" | awk '/^Pages:/ {print $2}')
  ocr_ok=1
  for (( i = 0; i < np; i++ )); do
    printf "\r      page %d/%d" $((i + 1)) $np
    pg=$(printf %04d $i)
    magick -density "$DPI" "${cleaned}[$i]" -colorspace Gray \
      -units PixelsPerInch -density "$DPI" "$tmp/ocr-$pg.png"
    # --psm 3 = normal layout analysis, no orientation detection
    if ! tesseract "$tmp/ocr-$pg.png" "$tmp/text-$pg" -l "$OCR_LANG" --psm 3 \
         -c textonly_pdf=1 pdf >/dev/null 2>&1; then
      ocr_ok=0; break
    fi
  done
  echo

  if (( ocr_ok )) &&
     qpdf --empty --pages "$tmp"/text-*.pdf -- "$tmp/text.pdf" 2>/dev/null &&
     qpdf "$cleaned" --overlay "$tmp/text.pdf" -- "$tmp/ocr.pdf" 2>/dev/null &&
     [[ "$(layout "$cleaned")" == "$(layout "$tmp/ocr.pdf")" ]]; then
    final="$tmp/ocr.pdf"
    echo "      Text layer added — page layout verified unchanged"
  else
    echo "      Warning: OCR failed or would have changed the page layout — saved without searchable text"
  fi
else
  echo "[6/6] Skipping OCR"
fi

cp "$final" "$out"

pages_out=$(pdfinfo "$out" 2>/dev/null | awk '/^Pages:/ {print $2}')
size=$(du -h "$out" | awk '{print $1}')
echo "Done: $out ($pages_out pages, $size)"

if (( OPEN )); then open "$out"; fi
