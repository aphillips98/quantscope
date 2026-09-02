#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${project_dir}/install_llamacpp.sh"
tmux_installer="${project_dir}/install_tmux.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

bash -n "$installer"
bash -n "$tmux_installer"
"$installer" --help >/dev/null
"$tmux_installer" --help >/dev/null
"$installer" module \
    --profile test-profile \
    --prefix "$tmp_dir/prefix" \
    --module-root "$tmp_dir/modules" \
    --version test

module_file="$tmp_dir/modules/test-profile/llamacpp/test.lua"
[[ -f "$module_file" ]]
grep -Fq "local base = \"$tmp_dir/prefix\"" "$module_file"
grep -Fq 'prepend_path("PATH", pathJoin(base, "bin"))' "$module_file"

"$tmux_installer" module \
    --version test \
    --prefix "$tmp_dir/tmux-prefix" \
    --module-root "$tmp_dir/modules"

tmux_module_file="$tmp_dir/modules/tmux/test.lua"
[[ -f "$tmux_module_file" ]]
grep -Fq "local root = \"$tmp_dir/tmux-prefix\"" "$tmux_module_file"
grep -Fq 'prepend_path("PATH", pathJoin(root, "bin"))' "$tmux_module_file"

printf 'Smoke test passed.\n'
