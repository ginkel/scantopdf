#!/bin/bash

usage()
{
cat << EOF
usage: $0 options [file.pdf]

This script scans a document and produces a PDF file.

OPTIONS:
   -h      Show this message
   -b      Do not attempt to detect blank pages
   -d      Duplex
   -f      Do not try to detect double feeds
   -g      Keep grayscale image
   -m      Mode, e.g. Lineart or Gray
   -n      Do not perform postprocessing
   -o      Do not perform OCR
   -r      Resolution in DPI
   -s      Page number to start naming files with
   -t      Title of PDF file
EOF
}

function from_scientific() {
  local scientific=$1
  if [[ ${scientific} == *"e+"* ]]; then
    local base=$(echo $scientific | cut -d 'e' -f1)
    local exp=$(($(echo $scientific | cut -d 'e' -f2)*1))
    local converted=$(bc -l <<< "$base*(10^$exp)")
    echo $converted
  else
    echo $scientific
  fi
}

DUPLEX="0"
SOURCE="ADF Front"
MODE="Gray"
RESOLUTION="600"
BATCH_START="1"
TITLE=`uuidgen`
SUBJECT="${TITLE}"
OCR="1"
NOPREPROCESS="0"
NOBLANKPAGEDETECT="0"
DOUBLEFEED="yes"
ABBYYOCR=abbyyocr11

while getopts "hdgm:nor:s:t:fib" OPTION; do
  case $OPTION in
    h) usage; exit 1 ;;
    b) NOBLANKPAGEDETECT=1 ;;
    d) DUPLEX="1"; SOURCE="ADF Duplex" ;;
    f) DOUBLEFEED="no" ;;
    m) MODE=$OPTARG ;;
    n) NOPREPROCESS=1 ;;
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
  --device canon_dr \
  --batch="${DEST_DIR}/out%03d.pnm" \
  --batch-start=${BATCH_START} \
  --resolution=${RESOLUTION} \
  -l 0 \
  -t 0 \
  -x 210 \
  -y 297 \
  --rollerdeskew=yes \
  --stapledetect=yes \
  --df-thickness=${DOUBLEFEED} \
  --mode=${MODE} \
  --source "${SOURCE}" \
  --page-width 210 \
  --page-height 350

if [ "${DUPLEX}" -eq "1" ]; then
  if [ "${NOBLANKPAGEDETECT}" -eq "0" ]; then
    echo "Detecting blank pages..."
    for i in "${DEST_DIR}/out"*.pnm; do
      histogram=`convert "${i}" -threshold 50% -format %c histogram:info:-`
      white=`echo "${histogram}" | grep "#FFFFFF" | sed -n 's/^ *\(.*\):.*$/\1/p'`
      black=`echo "${histogram}" | grep "#000000" | sed -n 's/^ *\(.*\):.*$/\1/p'`
      white_corrected=$(from_scientific ${white})
      black_corrected=$(from_scientific ${black})
      blank=`echo "scale=4; ${black_corrected}/${white_corrected} < 0.005" | bc`
      if [[ "${blank}" -eq "1" ]]; then
        echo "${i} seems to be blank - removing it..."
        rm "${i}"
      fi
    done
  fi
fi

#for i in "${DEST_DIR}/out"*.pnm; do
#  pnmtotiff \
#    -xresolution "${RESOLUTION}" \
#    -yresolution "${RESOLUTION}" \
#    -lzw "${i}" > ${DEST_DIR}/`basename "${i}" .pnm`.tif
#  rm "${i}"
#done

if [ "${NOPREPROCESS}" -eq "0" ]; then
  echo "Converting to b/w..."
  for i in "${DEST_DIR}/out"*.pnm; do
    convert "${i}" -colorspace gray -level 10%,90%,1 -blur 2 +dither -monochrome "${DEST_DIR}/bw_`basename "${i}" .pnm`.tif"
  done

  echo "Removing borders..."
  for i in "${DEST_DIR}/bw_"*.tif; do
    width=`identify -format "%w" ${i}`
    height=`identify -format "%h" ${i}`
    echo "Width, height: ${width} / ${height}"
    convert "${i}" -stroke black -fill black -draw "rectangle 0,$((height-50)) ${width},${height}" -draw "rectangle $((width-50)),0 ${width},${height}" +matte "${DEST_DIR}/border_`basename "${i}" .tif`.tif"
    convert "${DEST_DIR}/border_`basename "${i}" .tif`.tif" -fill white -draw "color $((width-1)),$((height-1)) floodfill" "${DEST_DIR}/whitened_`basename "${i}" .tif`.tif"
  done
fi

if [ ! -z "$DEST_FILE" ]; then
  if [ "${NOPREPROCESS}" -eq "0" ]; then
    tiffcp "${DEST_DIR}/whitened_"*".tif" "${DEST_DIR}/all.tif"
  else
    for i in "${DEST_DIR}/out"*.pnm; do
      convert "${i}" "${DEST_DIR}/`basename "${i}" .pnm`.tif"
      tiffcp "${DEST_DIR}/out"*".tif" "${DEST_DIR}/all.tif"
    done
  fi

  if [ ${OCR} -eq "1" ]; then
    tesseract "${DEST_DIR}/all.tif" "${DEST_DIR}/result" -l deu+eng pdf
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

