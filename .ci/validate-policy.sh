#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
set -euo pipefail
: "${CI_TOOL_BINARY:?Use the verified ccid adapter to check the runtime contract}"
policy=$(nix build --no-link --print-out-paths .#checks.x86_64-linux.repository-policy)
"$CI_TOOL_BINARY" forge validate --policy "$policy"
"$CI_TOOL_BINARY" forge plan --policy "$policy" --repository widget
# Receipt for consumers adding this exact public module revision to their lock.
if [[ -n ${CI_COMMIT_SHA:-} ]]; then
  nix flake prefetch --json "github:corbet-nix/nixci-corbet-ch/$CI_COMMIT_SHA"
fi
