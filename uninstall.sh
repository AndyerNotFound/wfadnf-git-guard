#!/usr/bin/env bash
# 卸载：撤钩子软链 + 删程序，规则目录保留（里面可能有你写的规则）
set -uo pipefail
GUARD_ROOT="${GUARD_ROOT:-$HOME/.config/git}"
BIN_DIR="${GUARD_BIN_DIR:-$HOME/bin}"
rm -f "$BIN_DIR/git-guard" "$BIN_DIR/wsnap"
for d in $(find "${1:-$HOME}" -maxdepth 5 -name .git -prune -print 2>/dev/null | sed 's|/\.git$||'); do
  for h in pre-commit pre-push; do
    [ -L "$d/.git/hooks/$h" ] && rm -f "$d/.git/hooks/$h"
  done
  sed -i '/^# >>> git-guard/,/^# <<< git-guard/d' "$d/.git/info/exclude" 2>/dev/null
done
git config --global --unset init.templateDir 2>/dev/null || true
echo "已卸载。规则仍保留在 $GUARD_ROOT（需要时手动删）。"
