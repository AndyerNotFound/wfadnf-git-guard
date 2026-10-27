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
# 还原安装前记录的原模板目录；没有记录才清空
prev_file="$GUARD_ROOT/guard/prev-templateDir"
if [ -s "$prev_file" ]; then
  git config --global init.templateDir "$(cat "$prev_file")"
  echo "已还原原 init.templateDir: $(cat "$prev_file")"
  rm -f "$prev_file"
else
  git config --global --unset init.templateDir 2>/dev/null || true
fi
# 还原安装前记录的原 core.excludesFile；是 guard 自己写的才清空
prev_excl_file="$GUARD_ROOT/guard/prev-excludesFile"
cur_excl=$(git config --global --get core.excludesFile 2>/dev/null || true)
if [ -s "$prev_excl_file" ]; then
  git config --global core.excludesFile "$(cat "$prev_excl_file")"; rm -f "$prev_excl_file"
elif [ "$cur_excl" = "$GUARD_ROOT/ignore" ]; then
  git config --global --unset core.excludesFile 2>/dev/null || true
fi
echo "已卸载。规则仍保留在 $GUARD_ROOT（需要时手动删）。"
