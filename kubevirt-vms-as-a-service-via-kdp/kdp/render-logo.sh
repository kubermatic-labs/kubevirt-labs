#!/usr/bin/env bash
# Render a source image into kdp/logo.png and kdp/logo-configmap.yaml.
# KDP takes the logo as a data URI in a ConfigMap key, so the PNG is inlined.
# The stock source is kdp/logo-src.png, which already has a transparent background.
set -euo pipefail

src="${1:-$(dirname "${BASH_SOURCE[0]}")/logo-src.png}"
size="${2:-192}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/logo.png"

command -v sips >/dev/null || { echo "sips not found (macOS only)"; exit 1; }

# -Z fits within the box and preserves aspect ratio; no padding, so no white bars.
# sips downscales premultiplied, so a transparent source stays transparent with clean edges.
sips -Z "$size" "$src" --out "$out" >/dev/null
# pngquant keeps alpha (it quantises RGBA and writes a tRNS palette), optipng only re-packs.
command -v pngquant >/dev/null && pngquant --force --quality 65-90 --output "$out" "$out" 2>/dev/null || true
command -v optipng  >/dev/null && optipng -quiet -o5 "$out" 2>/dev/null || true

python3 - "$out" "$here/logo-configmap.yaml" <<'PY'
import base64, sys, pathlib
png, dest = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
uri = "data:image/png;base64," + base64.b64encode(png.read_bytes()).decode()
dest.write_text(f"""---
# Service logo for the KDP catalog. KDP expects a data URI under the key referenced by
# Service.spec.catalogMetadata.logo.configMap.key. Source artwork: kdp/logo-src.png
# Regenerate with: just kdp-logo kdp/logo-src.png
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubev.k8c.io-logo
  namespace: default
data:
  logo: {uri}
""")
print(f"{png.name}: {png.stat().st_size} bytes -> data URI {len(uri)} chars")
PY
