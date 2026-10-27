#!/usr/bin/env bash
# Install git-guard + wsnap (idempotent: existing rule files are never overwritten)
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
GUARD_ROOT="${GUARD_ROOT:-$HOME/.config/git}"
GUARD_DIR="${GUARD_DIR:-$GUARD_ROOT/guard}"
BIN_DIR="${GUARD_BIN_DIR:-$HOME/bin}"

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
mkdir -p "$GUARD_ROOT/template/hooks" "$GUARD_ROOT/template/info" "$GUARD_DIR" "$BIN_DIR"

cp "$SRC/lib/guard-lib.sh" "$GUARD_ROOT/guard-lib.sh"
install -m 755 "$SRC/share/template/hooks/pre-commit" "$GUARD_ROOT/template/hooks/pre-commit"
install -m 755 "$SRC/share/template/hooks/pre-push"   "$GUARD_ROOT/template/hooks/pre-push"
cp "$SRC/share/template/info/exclude" "$GUARD_ROOT/template/info/exclude"
install -m 755 "$SRC/bin/git-guard" "$BIN_DIR/git-guard"
install -m 755 "$SRC/bin/wsnap"     "$BIN_DIR/wsnap"

# Notification action script: bake absolute paths in at install time (termux action env has no PATH/HOME)
act_src="$SRC/share/guard/notify-action.sh"
if [ -f "$act_src" ]; then
  # Termux has no /usr/bin/env; the shebang must be an absolute bash path
  bashbin="${PREFIX:-/usr}/bin/bash"
  [ -x "$bashbin" ] || bashbin="/bin/bash"
  sed -e "1s|^#!.*|#!$bashbin|" \
      -e "s|__HOME__|$HOME|g" \
      -e "s|__PREFIX__|${PREFIX:-/usr}|g" \
      -e "s|__GUARD_ROOT__|$GUARD_ROOT|g" \
      "$act_src" > "$GUARD_DIR/notify-action.sh"
  chmod 755 "$GUARD_DIR/notify-action.sh"
  echo "  Notification action: ${GUARD_DIR/#$HOME/~}/notify-action.sh"
fi

for f in "$SRC"/share/guard/*.txt; do
  dst="$GUARD_DIR/$(basename "$f")"
  [ -f "$dst" ] || { cp "$f" "$dst"; echo "  Rule: ${dst/#$HOME/~}"; }
done

# Save the previous init.templateDir and restore it on uninstall (otherwise the user's own template config is lost forever)
prev_tpl=$(git config --global --get init.templateDir 2>/dev/null || true)
if [ -n "$prev_tpl" ] && [ "$prev_tpl" != "$GUARD_ROOT/template" ]; then
  printf '%s' "$prev_tpl" > "$GUARD_DIR/prev-templateDir"
  echo "  Recorded previous init.templateDir: $prev_tpl (restored on uninstall)"
fi
# Save the previous core.excludesFile and restore it on uninstall
prev_excl=$(git config --global --get core.excludesFile 2>/dev/null || true)
if [ -n "$prev_excl" ] && [ "$prev_excl" != "$GUARD_ROOT/ignore" ]; then
  printf '%s' "$prev_excl" > "$GUARD_DIR/prev-excludesFile"
  echo "  Recorded previous core.excludesFile: $prev_excl (restored on uninstall)"
fi
git config --global init.templateDir "$GUARD_ROOT/template"
[ -f "$GUARD_ROOT/ignore" ] || cp "$SRC/share/ignore" "$GUARD_ROOT/ignore" 2>/dev/null || true
[ -f "$GUARD_ROOT/ignore" ] && git config --global core.excludesFile "$GUARD_ROOT/ignore"

echo
echo "Installed. Next steps:"
 echo "  1) Put your remote prefix into ${GUARD_DIR/#$HOME/~}/owners.txt (otherwise third-party repos get hooked too)"
echo "  2) Put runtime data directories into ${GUARD_DIR/#$HOME/~}/protected-roots.txt"
echo "  3) $BIN_DIR/git-guard install ~/your-workspace   # hook existing repos"
echo "  4) $BIN_DIR/git-guard snapshot               # build runtime file fingerprints"
echo "  5) $BIN_DIR/wsnap init && $BIN_DIR/wsnap hook on"
