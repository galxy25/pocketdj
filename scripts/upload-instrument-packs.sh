#!/usr/bin/env bash
# Publish the PocketDJ virtual-instrument packs to the public rips bucket.
#
# The native Instruments tab (apple/PocketDJ/Studio/InstrumentPacks.swift) reads
# rips/instruments/index.json and downloads each bank from
#   Config.instrumentsBase.appendingPathComponent(bankKey)
# where Config.instrumentsBase == <ripsBase>/rips/instruments. So bank keys in the
# manifest MUST be RELATIVE to rips/instruments/ (e.g. "banks/<file>.sf2") — NOT the
# full bucket-root key. Using a full "rips/instruments/banks/..." key double-prefixes
# the URL and every download 403s. (This bit us once; that is why this script exists.)
#
# Everything lives under the public "rips/" prefix (the only prefix the bucket policy
# makes world-readable). Uploads use the same AWS profile as every other S3 publisher.
set -euo pipefail

BUCKET="${POCKETDJ_RIPS_BUCKET:-pocketdj-rips-011183829623}"
REGION="${AWS_REGION:-us-west-2}"
PROFILE="${AWS_PROFILE_OVERRIDE:-${AWS_PROFILE:-levi}}"
PREFIX="rips/instruments"

# arg 1: path to the SoundFont (.sf2). Default: GeneralUser GS 2.0.3.
SF2="${1:-}"
if [[ -z "$SF2" || ! -f "$SF2" ]]; then
  echo "usage: $0 /path/to/GeneralUser-GS.sf2" >&2
  echo "  (download from https://github.com/mrbumpy409/GeneralUser-GS — free to redistribute)" >&2
  exit 1
fi

BANK_FILE="banks/generaluser-gs-2.0.3.sf2"   # relative key — see the header note
BYTES=$(stat -f%z "$SF2" 2>/dev/null || stat -c%s "$SF2")
SHA=$(shasum -a 256 "$SF2" | awk '{print $1}')

echo "bank: $SF2 ($BYTES bytes, sha256 $SHA)"

# Seven GM melodic instruments sharing the one bank (dedup by bankKey happens client-side).
TMP_INDEX="$(mktemp -t instruments-index).json"
cat > "$TMP_INDEX" <<JSON
{
  "version": 1,
  "attribution": "GeneralUser GS by S. Christian Collins (schristiancollins.com) — free to use and distribute; see the GeneralUser GS License v2.0.",
  "sharedBanks": [
    { "key": "$BANK_FILE", "bytes": $BYTES, "sha256": "$SHA" }
  ],
  "packs": [
    { "id": "pack_piano",           "name": "Piano",           "instrument": "piano",          "program": 0,  "bankKey": "$BANK_FILE", "bytes": $BYTES },
    { "id": "pack_violin",          "name": "Violin",          "instrument": "violin",         "program": 40, "bankKey": "$BANK_FILE", "bytes": $BYTES },
    { "id": "pack_bass_guitar",     "name": "Bass Guitar",     "instrument": "bassGuitar",     "program": 33, "bankKey": "$BANK_FILE", "bytes": $BYTES },
    { "id": "pack_acoustic_guitar", "name": "Acoustic Guitar", "instrument": "acousticGuitar", "program": 25, "bankKey": "$BANK_FILE", "bytes": $BYTES },
    { "id": "pack_trumpet",         "name": "Trumpet",         "instrument": "trumpet",        "program": 56, "bankKey": "$BANK_FILE", "bytes": $BYTES },
    { "id": "pack_clarinet",        "name": "Clarinet",        "instrument": "clarinet",       "program": 71, "bankKey": "$BANK_FILE", "bytes": $BYTES },
    { "id": "pack_harp",            "name": "Harp",            "instrument": "harp",           "program": 46, "bankKey": "$BANK_FILE", "bytes": $BYTES }
  ]
}
JSON

aws s3 cp "$SF2" "s3://$BUCKET/$PREFIX/$BANK_FILE" \
  --content-type application/octet-stream --profile "$PROFILE" --region "$REGION"
# no-cache on the index so a manifest fix reaches devices on the next Instruments-tab open.
aws s3 cp "$TMP_INDEX" "s3://$BUCKET/$PREFIX/index.json" \
  --content-type application/json --cache-control no-cache --profile "$PROFILE" --region "$REGION"

rm -f "$TMP_INDEX"
echo "done → https://$BUCKET.s3.$REGION.amazonaws.com/$PREFIX/index.json"
