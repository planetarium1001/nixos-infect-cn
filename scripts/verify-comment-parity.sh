#!/usr/bin/env bash
# ===========================================================================
# 校验 nixos-infect.en.sh 与 nixos-infect.sh：代码完全一致，仅注释不同。
# ---------------------------------------------------------------------------
# 用法: bash scripts/verify-comment-parity.sh
# 退出码: 0 一致；1 不一致（会打印逐行 diff）
#
# 原理: 先去掉整行注释，再去掉行尾注释，然后逐行比较。
# 字符串里出现的 "#" 在两份文件中本身就必须一致，因此这种粗暴的去注释
# 不会掩盖真实的代码差异；它只能容忍注释文本不同。
# ===========================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

zh="nixos-infect.sh"
en="nixos-infect.en.sh"

[ -f "$zh" ] || { echo "missing $zh" >&2; exit 1; }
[ -f "$en" ] || { echo "missing $en" >&2; exit 1; }

tmpdir=$(mktemp -d) || exit 1
trap 'rm -rf "$tmpdir"' EXIT

strip_comments() {
  # 整行注释 -> 空行；行尾注释 -> 去掉。保留空行，方便 diff 定位。
  sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]+#.*$//' "$1"
}

strip_comments "$zh" >"$tmpdir/zh.stripped"
strip_comments "$en" >"$tmpdir/en.stripped"

if diff -u "$tmpdir/zh.stripped" "$tmpdir/en.stripped"; then
  echo "OK: $zh and $en have identical code; only comments differ."
else
  echo "FAIL: code differs between $zh and $en (see diff above)." >&2
  exit 1
fi
