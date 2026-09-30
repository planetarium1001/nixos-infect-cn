#!/usr/bin/env bash
# ===== build.sh =====
# 把 modules/ 下的脚本合并成单一可执行文件
set -euo pipefail

MODULES=(
  00-base.sh
  10-probe.sh
  20-config.sh
  30-install.sh
)

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$ROOT/dist/nixos-infect.sh}"
mkdir -p "$(dirname "$OUT")"

{
  for m in "${MODULES[@]}"; do
    echo "# ==========================================================================="
    echo "# module: $m"
    echo "# ==========================================================================="
    # 去掉模块里的 shebang 行和 BASH_SOURCE 入口守卫（只在合并产物末尾保留一个）
    if [ "$m" = "${MODULES[-1]}" ]; then
      cat "$ROOT/modules/$m"
    else
      sed -e '1{/^#!/d;}' "$ROOT/modules/$m"
    fi
    echo ""
  done
} > "$OUT"

chmod +x "$OUT"
lines=$(wc -l < "$OUT")
echo "built: $OUT ($lines lines)"
