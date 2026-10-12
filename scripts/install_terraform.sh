#!/usr/bin/env bash
# Install a pinned Terraform, verifying the download against HashiCorp's published
# checksums. Used in CI in place of a third-party setup action.
#   scripts/install_terraform.sh 1.16.5
set -euo pipefail
version="${1:?usage: install_terraform.sh VERSION}"
os="linux"; arch="amd64"
base="https://releases.hashicorp.com/terraform/${version}"
zip="terraform_${version}_${os}_${arch}.zip"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/$zip" "$base/$zip"
curl -fsSL -o "$work/sums" "$base/terraform_${version}_SHA256SUMS"
(cd "$work" && grep " $zip\$" sums | sha256sum -c -)
bin="${TERRAFORM_BIN:-$HOME/.local/bin}"
mkdir -p "$bin"
unzip -q -o "$work/$zip" terraform -d "$bin"
"$bin/terraform" version | head -1
