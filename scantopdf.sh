#!/bin/bash

usage()
{
cat << EOF
usage: $0 options [file.pdf]

This script scans a document and produces a PDF file.

OPTIONS:
   -h      Show this message
   -d      Duplex
   -m      Mode, e.g. Lineart or Gray
   -o      Do not perform OCR
   -r      Resolution in DPI
   -s      Page number to start naming files with
   -t      Title of PDF file
EOF
}

DUPLEX="0"
SOURCE="ADF Front"
MODE="Gray"
RESOLUTION="600"
BATCH_START="1"
TITLE=`uuidgen`
SUBJECT="${TITLE}"
OCR="1"

while getopts "hdm:or:s:t:" OPTION; do
  case $OPTION in
    h) usage; exit 1 ;;
    d) DUPLEX="1"; SOURCE="ADF Duplex" ;;
    m) MODE=$OPTARG ;;
    o) OCR="0" ;;
    r) RESOLUTION=$OPTARG ;;
    s) BATCH_START=$OPTARG ;;
    t) TITLE="$OPTARG"; SUBJECT="$OPTARG" ;;
  esac
done
shift $(($OPTIND - 1))

DEST_DIR="."
unset DEST_FILE

if [ $# == 1 ]; then
  DEST_FILE="$1"
  if [ -e "$DEST_FILE" ]; then
    echo Error: $1 already exists
    exit 1
  fi
  DEST_DIR=$(mktemp -td scantopdf.XXXXXXXXX) || exit 1
fi

scanimage \
  --batch="${DEST_DIR}/out%03d.pnm" \
  --batch-start=${BATCH_START} \
  --resolution=${RESOLUTION} \
  --page-width 210 \
  --page-height 297 \
  -l 0 \
  -t 0 \
  -x 210 \
  -y 297 \
  --rollerdeskew=yes \
  --swcrop=yes \
  --stapledetect=yes \
  --df-thickness=yes \
  --mode=${MODE} \
  --source "${SOURCE}"

if [ "${DUPLEX}" -eq "1" ]; then
  echo "Detecting blank pages..."
  for i in "${DEST_DIR}/out"*.pnm; do
    histogram=`convert "${i}" -threshold 50% -format %c histogram:info:-`
    white=`echo "${histogram}" | grep "white" | sed -n 's/^ *\(.*\):.*$/\1/p'`
    black=`echo "${histogram}" | grep "black" | sed -n 's/^ *\(.*\):.*$/\1/p'`
    blank=`echo "scale=4; ${black}/${white} < 0.005" | bc`
    if [ ${blank} -eq "1" ]; then
      echo "${i} seems to be blank - removing it..."
      rm "${i}"
    fi
  done
fi

#for i in "${DEST_DIR}/out"*.pnm; do
#  pnmtotiff \
#    -xresolution "${RESOLUTION}" \
#    -yresolution "${RESOLUTION}" \
#    -lzw "${i}" > ${DEST_DIR}/`basename "${i}" .pnm`.tif
#  rm "${i}"
#done

echo "Converting to b/w..."
for i in "${DEST_DIR}/out"*.pnm; do
  convert "${i}" -colorspace gray -level 10%,90%,1 -blur 2 +dither -monochrome "${DEST_DIR}/bw_`basename "${i}" .pnm`.tif"
done

echo "Removing borders..."
for i in "${DEST_DIR}/bw_"*.tif; do
  width=`identify -format "%w" ${i}`
  height=`identify -format "%h" ${i}`
  convert "${i}" -stroke black -fill black -draw "rectangle 0,$((height-75)) ${width},${height}" -draw "rectangle $((width-75)),0 ${width},${height}" +matte "${DEST_DIR}/border_`basename "${i}" .tif`.tif"
  convert "${DEST_DIR}/border_`basename "${i}" .tif`.tif" -fill white -draw "color $((width-1)),$((height-1)) floodfill" +matte "${DEST_DIR}/whitened_`basename "${i}" .tif`.tif"
done

if [ ! -z "$DEST_FILE" ]; then
  tiffcp "${DEST_DIR}/whitened_"*".tif" "${DEST_DIR}/all.tif"

  if [ ${OCR} -eq "1" ]; then
    abbyyocr9 \
      --progressInformation \
      -id \
      --convertToBWImage \
      --recognitionLanguage German \
      --inputFileName "${DEST_DIR}/all.tif" \
      --outputFileFormat PDFA \
      --pdfaExportMode ImageOnText \
      --pdfaReleasePageSizeByLayoutSize \
      --pdfaQuality 100 \
      --outputFileName "${DEST_DIR}/result.pdf"
  else
    tiff2pdf \
      -j -q 50 \
      -pA4 -x "${RESOLUTION}" -y "${RESOLUTION}" \
      -f \
      -t "${TITLE}" \
      -s "${SUBJECT}" \
      -o "${DEST_DIR}/result.pdf" "${DEST_DIR}/all.tif"
  fi

  mv "${DEST_DIR}/result.pdf" "$DEST_FILE"

  rm -rf "${DEST_DIR}"
fi

