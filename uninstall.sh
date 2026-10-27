#!/usr/bin/env bash
# Uninstall: remove hook symlinks + binaries; keep the rules dir (may contain your own rules)
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
# Restore the pre-install template dir recorded at install time; unset only if none was recorded
prev_file="$GUARD_ROOT/guard/prev-templateDir"
if [ -s "$prev_file" ]; then
  git config --global init.templateDir "$(cat "$prev_file")"
  echo "Restored previous init.templateDir: $(cat "$prev_file")"
  rm -f "$prev_file"
else
  git config --global --unset init.templateDir 2>/dev/null || true
fi
# Restore the pre-install core.excludesFile; unset only if guard itself set it
prev_excl_file="$GUARD_ROOT/guard/prev-excludesFile"
cur_excl=$(git config --global --get core.excludesFile 2>/dev/null || true)
if [ -s "$prev_excl_file" ]; then
  git config --global core.excludesFile "$(cat "$prev_excl_file")"; rm -f "$prev_excl_file"
elif [ "$cur_excl" = "$GUARD_ROOT/ignore" ]; then
  git config --global --unset core.excludesFile 2>/dev/null || true
fi
echo "Uninstalled. Rules are kept in $GUARD_ROOT (delete manually if unwanted)."
