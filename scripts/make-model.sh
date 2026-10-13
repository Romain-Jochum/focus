#!/bin/bash
# Exports the phone detector, RF-DETR nano (Roboflow, Apache-2.0) at 384 px, to
# Core ML FP16 at Resources/rfdetr-nano.mlpackage (52 MB, not in git).
# Needs uv (https://docs.astral.sh/uv/); the Python packages go to uv's cache,
# nothing is installed globally. Pinned to the versions that produced the
# shipped model. See research/10-rfdetr.md.
set -eu

OUT="${1:-Resources/rfdetr-nano.mlpackage}"
command -v uv >/dev/null || { echo "error: uv not found; install it from https://docs.astral.sh/uv/" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

uv run --quiet --no-project --python 3.12 \
    --with rfdetr==1.9.4 --with coremltools==9.0 --with torch==2.14.1 --with torchvision==0.29.1 \
    python - "$WORK" <<'PY'
import sys
from rfdetr import RFDETRNano
RFDETRNano().export(output_dir=sys.argv[1], format="coreml", shape=(384, 384), fp16=True, verbose=False, coreml_precision="float16")
PY

rm -rf "$OUT"
mv "$WORK/rfdetr-nano.mlpackage" "$OUT"
echo "wrote $OUT"
