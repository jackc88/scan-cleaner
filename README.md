# scan-cleaner
This script will collate and clean up the scanned PDFs into one merged PDF.  It will straightened misaligned scans, improve contrast and uses OCR to make the document searchable.

OSX Dependencies:
  brew install imagemagick ghostscript poppler tesseract qpdf

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

imagemagick: straightening, contrast, and cleanup
ghostscript: lets ImageMagick read PDFs
poppler: provides pdfimages and pdfinfo for detecting DPI, bit depth, and page count
tesseract: reads the text for OCR
qpdf: lays the text layer over the pages

  Note:
  If you need OCR in languages other than English (for example -l eng+spa), also run:
    brew install tesseract-lang
  Avoid: OCRmyPDF - Caused images to mistakenly rotate images.

  Tested on Canon ImageClass document feeder for double-sided documents.
  
