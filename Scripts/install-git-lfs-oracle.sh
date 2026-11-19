#!/usr/bin/env bash
set -euo pipefail

# GitLFSKit's command compatibility target is 3.7.1. Runner images can ship
# newer git-lfs releases whose help and diagnostic text intentionally differ.
version=3.7.1
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)
    asset="git-lfs-darwin-arm64-v${version}.zip"
    checksum=76260fb34f4ee622ff0a66b857e5954aa49c7e343a92e57a1ec4a760618c94b2
    ;;
  Darwin-x86_64)
    asset="git-lfs-darwin-amd64-v${version}.zip"
    checksum=b5b1b641c0648c83661fa9eda991cd3eff945264dabc2cdf411a80dfe7ec0970
    ;;
  Linux-x86_64)
    asset="git-lfs-linux-amd64-v${version}.tar.gz"
    checksum=1c0b6ee5200ca708c5cebebb18fdeb0e1c98f1af5c1a9cba205a4c0ab5a5ec08
    ;;
  *) echo "Unsupported Git LFS oracle platform" >&2; exit 1 ;;
esac

root="${RUNNER_TEMP:?}/git-lfs-oracle"
mkdir -p "$root"
curl --fail --location --retry 3 \
  "https://github.com/git-lfs/git-lfs/releases/download/v${version}/${asset}" \
  --output "$root/$asset"
if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$checksum" "$root/$asset" | sha256sum --check -
else
  printf '%s  %s\n' "$checksum" "$root/$asset" | shasum -a 256 --check -
fi
case "$asset" in
  *.zip) unzip -q -o "$root/$asset" -d "$root" ;;
  *.tar.gz) tar -xzf "$root/$asset" -C "$root" ;;
esac
"$root/git-lfs-$version/git-lfs" version
echo "$root/git-lfs-$version" >> "${GITHUB_PATH:?}"
