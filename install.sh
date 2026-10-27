#!/usr/bin/env bash
# 安装 git-guard + wsnap（幂等：已存在的规则文件不会被覆盖）
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
GUARD_ROOT="${GUARD_ROOT:-$HOME/.config/git}"
GUARD_DIR="${GUARD_DIR:-$GUARD_ROOT/guard}"
BIN_DIR="${GUARD_BIN_DIR:-$HOME/bin}"

command -v git >/dev/null || { echo "需要 git" >&2; exit 1; }
mkdir -p "$GUARD_ROOT/template/hooks" "$GUARD_ROOT/template/info" "$GUARD_DIR" "$BIN_DIR"

cp "$SRC/lib/guard-lib.sh" "$GUARD_ROOT/guard-lib.sh"
install -m 755 "$SRC/share/template/hooks/pre-commit" "$GUARD_ROOT/template/hooks/pre-commit"
install -m 755 "$SRC/share/template/hooks/pre-push"   "$GUARD_ROOT/template/hooks/pre-push"
cp "$SRC/share/template/info/exclude" "$GUARD_ROOT/template/info/exclude"
install -m 755 "$SRC/bin/git-guard" "$BIN_DIR/git-guard"
install -m 755 "$SRC/bin/wsnap"     "$BIN_DIR/wsnap"

for f in "$SRC"/share/guard/*.txt; do
  dst="$GUARD_DIR/$(basename "$f")"
  [ -f "$dst" ] || { cp "$f" "$dst"; echo "  规则: ${dst/#$HOME/~}"; }
done

git config --global init.templateDir "$GUARD_ROOT/template"
[ -f "$GUARD_ROOT/ignore" ] || cp "$SRC/share/ignore" "$GUARD_ROOT/ignore" 2>/dev/null || true
[ -f "$GUARD_ROOT/ignore" ] && git config --global core.excludesFile "$GUARD_ROOT/ignore"

echo
echo "已安装。接下来："
 echo "  1) 把你自己的远端前缀写进 ${GUARD_DIR/#$HOME/~}/owners.txt（否则第三方仓库也会被挂钩子）"
echo "  2) 把运行时数据目录写进 ${GUARD_DIR/#$HOME/~}/protected-roots.txt"
echo "  3) $BIN_DIR/git-guard install ~/你的工作区   # 给已有仓库挂钩子"
echo "  4) $BIN_DIR/git-guard snapshot               # 生成运行时文件指纹"
echo "  5) $BIN_DIR/wsnap init && $BIN_DIR/wsnap hook on"
