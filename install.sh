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

# 通知按钮的 action 脚本：把安装时的绝对路径烘进去（termux 的 action 环境没有 PATH/HOME）
act_src="$SRC/share/guard/notify-action.sh"
if [ -f "$act_src" ]; then
  # Termux 没有 /usr/bin/env，shebang 必须写成绝对 bash 路径
  bashbin="${PREFIX:-/usr}/bin/bash"
  [ -x "$bashbin" ] || bashbin="/bin/bash"
  sed -e "1s|^#!.*|#!$bashbin|" \
      -e "s|__HOME__|$HOME|g" \
      -e "s|__PREFIX__|${PREFIX:-/usr}|g" \
      -e "s|__GUARD_ROOT__|$GUARD_ROOT|g" \
      "$act_src" > "$GUARD_DIR/notify-action.sh"
  chmod 755 "$GUARD_DIR/notify-action.sh"
  echo "  通知动作: ${GUARD_DIR/#$HOME/~}/notify-action.sh"
fi

for f in "$SRC"/share/guard/*.txt; do
  dst="$GUARD_DIR/$(basename "$f")"
  [ -f "$dst" ] || { cp "$f" "$dst"; echo "  规则: ${dst/#$HOME/~}"; }
done

# 保存原有的 init.templateDir，卸载时还原（否则用户原有模板配置会被永久丢掉）
prev_tpl=$(git config --global --get init.templateDir 2>/dev/null || true)
if [ -n "$prev_tpl" ] && [ "$prev_tpl" != "$GUARD_ROOT/template" ]; then
  printf '%s' "$prev_tpl" > "$GUARD_DIR/prev-templateDir"
  echo "  已记录原 init.templateDir: $prev_tpl（卸载时还原）"
fi
# 保存原有的 core.excludesFile，卸载时还原
prev_excl=$(git config --global --get core.excludesFile 2>/dev/null || true)
if [ -n "$prev_excl" ] && [ "$prev_excl" != "$GUARD_ROOT/ignore" ]; then
  printf '%s' "$prev_excl" > "$GUARD_DIR/prev-excludesFile"
  echo "  已记录原 core.excludesFile: $prev_excl（卸载时还原）"
fi
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
