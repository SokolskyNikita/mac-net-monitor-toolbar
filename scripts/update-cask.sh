#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?usage: update-cask.sh VERSION SHA256}"
sha256="${2:?usage: update-cask.sh VERSION SHA256}"
cask="${root}/Casks/netmenu.rb"

if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version must be X.Y.Z, got: ${version}" >&2
  exit 1
fi
if [[ ! "${sha256}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "sha256 must be 64 hex chars, got: ${sha256}" >&2
  exit 1
fi

python3 - "$cask" "$version" "$sha256" <<'PY'
import pathlib, re, sys
path, version, sha256 = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
text, n1 = re.subn(r'^(  version )".*"', rf'\1"{version}"', text, count=1, flags=re.M)
text, n2 = re.subn(r'^(  sha256 ).*$', rf'\1"{sha256}"', text, count=1, flags=re.M)
if n1 != 1 or n2 != 1:
    raise SystemExit(f"failed to patch cask (version={n1} sha={n2})")
path.write_text(text)
print(f"updated {path} to {version} {sha256}")
PY
