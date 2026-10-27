#!/usr/bin/env bash
# git-guard shared library: blocks runtime private data / secrets from entering git
# Config: ~/.config/git/guard/   one-shot bypass: GUARD_OVERRIDE=1
GUARD_DIR="${GUARD_DIR:-$HOME/.config/git/guard}"
GUARD_MAX_FILE_BYTES="${GUARD_MAX_FILE_BYTES:-5242880}"
GUARD_MAX_SCAN_BYTES="${GUARD_MAX_SCAN_BYTES:-1048576}"
# Demo/placeholder values are not counted as secrets
G_MOCK_RE='(mock|dummy|fake|sample|placeholder|example|redacted|your[_-]?(api|key|token)|xxx{3,}|1234567890abc|PUT-YOUR|xxxxx)'
# Directories skipped only by the "soft" rules; high-confidence rules scan everywhere
G_SKIP_RE='/(lang|locales|i18n|tests?|__tests__|fixtures|__mocks__|docs?|examples?)/'

# TMPDIR fallback: often unset in cron/CI; when missing, temp file writes fail and checks silently stop working.
# Probe writable dirs in order (/tmp is often not writable on Android/Termux, so don't just fall back to /tmp).
g_pick_tmpdir() {
  local c
  for c in "${TMPDIR:-}" /tmp "$HOME/.cache" "$HOME/.tmp" "${PREFIX:-}/tmp"; do
    [ -n "$c" ] || continue
    [ -d "$c" ] && [ -w "$c" ] && { printf '%s' "$c"; return 0; }
  done
  c="$HOME/.cache/git-guard-tmp"
  mkdir -p "$c" 2>/dev/null && [ -w "$c" ] && { printf '%s' "$c"; return 0; }
  return 1
}
if ! TMPDIR=$(g_pick_tmpdir); then
  printf '%s\n' "git-guard: no writable temp directory found; checks cannot run (fails closed, not silent)" >&2
  printf '%s\n' "  Set TMPDIR to a writable directory and retry, or confirm it is harmless: GUARD_OVERRIDE=1 git ..." >&2
  [ "${GUARD_OVERRIDE:-0}" = "1" ] && TMPDIR="$HOME" || exit 1
fi
export TMPDIR

__g_blocked=0; __g_files=(); __g_reasons=()
__g_tmp=""

# Per-process temp dir: initialized explicitly (a command substitution would confine the assignment
# to a subshell and leak a new directory on every call). Result goes to the global $__g_tmp.
g_tmp_init() {
  [ -n "$__g_tmp" ] && return 0
  __g_tmp=$(mktemp -d "$TMPDIR/gg.XXXXXX" 2>/dev/null) || __g_tmp="$TMPDIR"
  return 0
}

g_tmpclean() {
  case "$__g_tmp" in ''|"$TMPDIR") ;; *) rm -rf "$__g_tmp";; esac
  __g_tmp=""
}

g_block() {
  local x
  for x in "${__g_files[@]:-}"; do [ "$x" = "$1" ] && return 0; done
  __g_blocked=1; __g_files+=("$1"); __g_reasons+=("$2")
}

g_pats() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null; }

# ============ Notification layer ============
# Push a system notification when blocked, saving a trip back to the Termux terminal.
# Notification failures never affect the block decision (all calls use || : plus timeout).
G_NOTIFY_TITLE_PREFIX="${GUARD_NOTIFY_TITLE_PREFIX:-git-guard}"

# Enabled unless: GUARD_NOTIFY=0, or $GUARD_DIR/notify.off exists, or no notifier command is available (silent skip)
g_notify_enabled() {
  [ "${GUARD_NOTIFY:-1}" = "0" ] && return 1
  [ -f "$GUARD_DIR/notify.off" ] && return 1
  command -v termux-notification >/dev/null 2>&1 && return 0
  command -v notify-send >/dev/null 2>&1 && return 0
  return 1
}

# Write the block report: opened by the "Details" button in the notification
# One-shot bypass token: written by the "Allow once" notification button; bound to repo+action,
# expires, and is consumed by the next matching run (like GUARD_OVERRIDE=1 but single-use)
g_one_shot_file() { printf '%s/override-one-shot' "$GUARD_DIR"; }

# $1=repo root  $2=action (commit/push); consumes the token and returns 0 on match
g_consume_one_shot() {
  local top="$1" kind="$2" f rf rk rt
  f=$(g_one_shot_file)
  [ -s "$f" ] || return 1
  rf=$(sed -n 's/^REPO=//p' "$f" | head -1)
  rk=$(sed -n 's/^KIND=//p' "$f" | head -1)
  rt=$(sed -n 's/^EXPIRE=//p' "$f" | head -1)
  if [ "$rf" != "$top" ] || [ "$rk" != "$kind" ]; then
    return 1
  fi
  rm -f "$f"
  if [ -n "$rt" ] && [ "$(date +%s)" -gt "$rt" ] 2>/dev/null; then
    return 1
  fi
  return 0
}

# Dismiss a previous block notification after checks pass (no cost unless a block actually happened)
g_notify_dismiss() {
  [ -f "$GUARD_DIR/last-block.txt" ] || return 0
  rm -f "$GUARD_DIR/last-block.txt"
  command -v termux-notification-remove >/dev/null 2>&1 && {
    timeout 8 termux-notification-remove git-guard >/dev/null 2>&1 || :
  }
  return 0
}

g_write_report() {
  local kind="$1" f="$GUARD_DIR/last-block.txt" i top
  mkdir -p "$GUARD_DIR" 2>/dev/null || return 0
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top="$PWD"
  {
    printf 'REPO=%s\n' "$top"
    printf 'KIND=%s\n' "$kind"
    printf 'TIME=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'FILES:\n'
    for i in "${!__g_files[@]}"; do
      printf '%s\t%s\n' "${__g_files[$i]}" "${__g_reasons[$i]}"
    done
    printf 'HINT:\n'
    printf '%s\n' "git restore --staged <file>      unstage"
    printf '%s\n' "git rm --cached <file>           remove tracked file from index"
    printf '%s\n' "echo '<pattern>' >> .gitignore   ignore permanently"
    printf '%s\n' ""
    printf 'Rules: %s/{deny-paths,deny-content,deny-content-soft}.txt\n' "$GUARD_DIR"
    printf 'False positive: echo '\''^/path$'\'' >> %s/allow-paths.txt\n' "$GUARD_DIR"
    printf 'One-shot bypass: GUARD_OVERRIDE=1 git ...\n'
  } > "$f" 2>/dev/null
  printf '%s' "$f"
}

g_notify() {
  local kind="$1" n i body f act title
  g_notify_enabled || return 0
  n=${#__g_files[@]}
  [ "$n" -eq 0 ] && return 0
  f=$(g_write_report "$kind")
  local top rb
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top="$PWD"
  rb="${top##*/}"
  title="$G_NOTIFY_TITLE_PREFIX blocked ${kind} · $rb · ${n} file(s)"
  body=""
  i=0
  while [ "$i" -lt "$n" ] && [ "$i" -lt 5 ]; do
    body="$body${__g_files[$i]} — ${__g_reasons[$i]}"$'\n'
    i=$((i + 1))
  done
  [ "$n" -gt 5 ] && body="$body… and $((n - 5)) more file(s)"$'\n'
  body="$body(open \"Details\" for the full report)"
  act="$GUARD_DIR/notify-action.sh"

  if command -v termux-notification >/dev/null 2>&1; then
    if [ -x "$act" ]; then
      timeout 8 termux-notification --title "$title" --content "$body" \
        --priority high --id git-guard --sound \
        --button1 "Unstage" --button1-action "$act undo" \
        --button2 "Allow once" --button2-action "$act allow" \
        --button3 "Details" --button3-action "$act view" \
        >/dev/null 2>&1 || :
    else
      timeout 8 termux-notification --title "$title" --content "$body" \
        --priority high --id git-guard --sound >/dev/null 2>&1 || :
    fi
  elif command -v notify-send >/dev/null 2>&1; then
    timeout 8 notify-send -u critical "$title" "$body" >/dev/null 2>&1 || :
  fi
  return 0
}

g_report() {
  [ "$__g_blocked" -eq 0 ] && return 0
  {
    printf '\n============ git-guard blocked %s ============\n' "$1"
    local i
    for i in "${!__g_files[@]}"; do
      printf '  x %s\n      -> %s\n' "${__g_files[$i]}" "${__g_reasons[$i]}"
    done
    printf '%s\n' "---------------------------------------------------------"
    printf '%s\n' "Runtime data / secrets / config were probably added by mistake. How to fix:"
    printf '%s\n' "  git restore --staged <file>        # unstage"
    printf '%s\n' "  git rm --cached <file>             # remove tracked file from index"
    printf '%s\n' "  echo '<pattern>' >> .gitignore     # ignore permanently"
    printf '%s\n' "Rules: ~/.config/git/guard/{deny-paths,deny-content,deny-content-soft}.txt"
    printf '%s\n' "False positives go into allow-paths.txt; only after confirming it is harmless: GUARD_OVERRIDE=1 git ..."
    printf '%s\n' "========================================================="
  } >&2
  [ "${GUARD_OVERRIDE:-0}" = "1" ] && { printf '%s\n' "git-guard: GUARD_OVERRIDE=1, allowing this run" >&2; return 0; }
  g_notify "$1"
  return 1
}

g_check_repo_root() {
  local top="$1" root
  [ -f "$GUARD_DIR/protected-roots.txt" ] || return 0
  while IFS= read -r root; do
    case "$root" in ''|'#'*) continue;; esac
    root="${root%/}"
    case "$top" in
      "$root"|"$root"/*)
        [ -f "$GUARD_DIR/allowed-repos.txt" ] && grep -qxF -- "$top" "$GUARD_DIR/allowed-repos.txt" && return 0
        g_block "$top" "this repo is inside protected runtime directory $root; commit/push denied by default"
        return 1;;
    esac
  done < "$GUARD_DIR/protected-roots.txt"
  return 0
}

g_allowed_path() {
  [ -f "$GUARD_DIR/allow-paths.txt" ] || return 1
  printf '/%s' "$1" | grep -qE -f <(g_pats "$GUARD_DIR/allow-paths.txt") 2>/dev/null
}

# Per-path check: locate the exact rule only on a hit (few rules, checked only for hit paths)
g_check_path() {
  local rel="$1" pp pat
  [ -f "$GUARD_DIR/deny-paths.txt" ] || return 0
  g_allowed_path "$rel" && return 0
  g_tmp_init; pp="$__g_tmp/pp.$$"
  g_pats "$GUARD_DIR/deny-paths.txt" > "$pp"
  if [ ! -s "$pp" ]; then rm -f "$pp"; return 0; fi
  # Single grep for the common miss case (most files take this fast path)
  if ! printf '/%s' "$rel" | grep -qE -f "$pp" 2>/dev/null; then rm -f "$pp"; return 0; fi
  while IFS= read -r pat; do
    case "$pat" in ''|'#'*) continue;; esac
    if printf '/%s' "$rel" | grep -qE -- "$pat" 2>/dev/null; then
      g_block "$rel" "path matched deny rule: $pat"; rm -f "$pp"; return 0
    fi
  done < "$pp"
  g_block "$rel" "path matched deny rule"; rm -f "$pp"
}

g_check_size() {
  [ -z "${2:-}" ] && return 0
  [ "$2" -gt "$GUARD_MAX_FILE_BYTES" ] && { g_block "$1" "file too large ($2 bytes); likely a database/backup/build artifact"; return 0; }
  return 0
}

g_skip_content_path() { printf '/%s' "$1" | grep -qE "$G_SKIP_RE"; }

# Single blob decision: truncate at MAX_SCAN_BYTES + filter placeholder values + rule match; $3 = i for case-insensitive
g_blob_match() {
  git cat-file -p "$1" 2>/dev/null | head -c "$GUARD_MAX_SCAN_BYTES" \
    | grep -avEi -- "$G_MOCK_RE" | grep -qa"${3:-}"E -f "$2"
}

# Content check: $1=relative path  $2=blob spec (":path" or "<sha>:path")
g_check_content_blob() {
  local rel="$1" spec="$2" d ps po
  g_allowed_path "$rel" && return 0
  g_tmp_init; d="$__g_tmp"; ps="$d/ps.$$"; po="$d/po.$$"
  if [ -f "$GUARD_DIR/deny-content.txt" ]; then
    g_pats "$GUARD_DIR/deny-content.txt" > "$ps"
    if [ -s "$ps" ] && g_blob_match "$spec" "$ps"; then
      g_block "$rel" "content matched high-confidence secret pattern"; rm -f "$ps" "$po"; return 0
    fi
  fi
  if [ -f "$GUARD_DIR/deny-content-soft.txt" ] && ! g_skip_content_path "$rel"; then
    g_pats "$GUARD_DIR/deny-content-soft.txt" > "$po"
    if [ -s "$po" ] && g_blob_match "$spec" "$po" i; then
      g_block "$rel" "content matched secret-assignment pattern"; rm -f "$ps" "$po"; return 0
    fi
  fi
  rm -f "$ps" "$po"
}

g_check_content() { g_check_content_blob "$1" ":$1"; }

# ---- Batch layer: handle the whole index/tree with a single fork ----

# Path layer: $1 = candidate path list
g_scan_paths() {
  local list="$1" d pp
  [ -s "$list" ] || return 0
  [ -f "$GUARD_DIR/deny-paths.txt" ] || return 0
  g_tmp_init; d="$__g_tmp"; pp="$d/bpp.$$"
  g_pats "$GUARD_DIR/deny-paths.txt" > "$pp"
  if [ -s "$pp" ]; then
    # Narrow to actual hits with one grep, then locate the exact rule per hit
    sed 's|^|/|' "$list" | grep -aE -f "$pp" 2>/dev/null | sed 's|^/||' > "$d/hit.$$"
    while IFS= read -r p; do
      [ -n "$p" ] && g_check_path "$p"
    done < "$d/hit.$$"
    rm -f "$d/hit.$$"
  fi
  rm -f "$pp"
}

# Size layer: $1 = "sha<TAB>path"; fetch all sizes with one batch-check
g_scan_sizes() {
  local pairs="$1" d sizes
  [ -s "$pairs" ] || return 0
  g_tmp_init; d="$__g_tmp"; sizes="$d/sz.$$"
  cut -f1 "$pairs" | sort -u | git cat-file --batch-check='%(objectname) %(objectsize)' 2>/dev/null \
    | awk '{print $1"\t"$2}' > "$sizes"
  awk -v max="$GUARD_MAX_FILE_BYTES" -F'\t' '
    NR==FNR { sz[$1]=$2; next }
    { s=sz[$1]; if (s != "" && s+0 > max) print $2"\t"s }
  ' "$sizes" "$pairs" > "$d/big.$$"
  while IFS=$'\t' read -r rel size; do
    [ -n "$rel" ] && g_check_size "$rel" "$size"
  done < "$d/big.$$"
  rm -f "$sizes" "$d/big.$$"
}

# Content candidates: $1 = index | <rev list file>; $2 = rules file; $3 = optional keep-list of paths
# Outputs "blob spec<TAB>path"; specs can be fed straight to git cat-file
g_content_candidates() {
  local src="$1" pats="$2" only="${3:-}" ci="${4:-}" d raw
  g_tmp_init; d="$__g_tmp"; raw="$d/cand.$$"
  : > "$raw"
  if [ "$src" = "index" ]; then
    git grep --cached -a -l -z -E ${ci:+-i} -f "$pats" 2>/dev/null | tr '\0' '\n' \
      | while IFS= read -r p; do [ -n "$p" ] && printf ':%s\t%s\n' "$p" "$p"; done > "$raw"
  else
    [ -s "$src" ] || return 0
    # Feed revs in chunks to avoid hitting the argv length limit on big pushes
    split -l 200 "$src" "$d/chunk.$$." 2>/dev/null
    for cf in "$d/chunk.$$."*; do
      [ -s "$cf" ] || continue
      git grep -a -l -z -E ${ci:+-i} -f "$pats" $(cat "$cf") -- . 2>/dev/null | tr '\0' '\n' \
        | while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf '%s\t%s\n' "$line" "${line#*:}"
          done >> "$raw"
    done
    rm -f "$d/chunk.$$."*
  fi
  if [ -n "$only" ] && [ -s "$only" ]; then
    awk -F'\t' 'NR==FNR { keep[$0]=1; next } ($2 in keep)' "$only" "$raw" > "$raw.f" 2>/dev/null
    mv "$raw.f" "$raw"
  fi
  cat "$raw"
  rm -f "$raw"
}

# Content layer: $1 = index | <rev list file>; $2 = optional restrict-to paths
g_scan_contents() {
  local src="$1" only="${2:-}" d ps po spec rel
  g_tmp_init; d="$__g_tmp"; ps="$d/cps.$$"; po="$d/cpo.$$"
  g_pats "$GUARD_DIR/deny-content.txt" > "$ps" 2>/dev/null
  g_pats "$GUARD_DIR/deny-content-soft.txt" > "$po" 2>/dev/null

  if [ -s "$ps" ]; then
    while IFS=$'\t' read -r spec rel; do
      [ -z "$rel" ] && continue
      g_allowed_path "$rel" && continue
      g_blob_match "$spec" "$ps" || continue
      g_block "$rel" "content matched high-confidence secret pattern"
    done < <(g_content_candidates "$src" "$ps" "$only")
  fi

  if [ -s "$po" ]; then
    while IFS=$'\t' read -r spec rel; do
      [ -z "$rel" ] && continue
      g_allowed_path "$rel" && continue
      g_skip_content_path "$rel" && continue
      g_blob_match "$spec" "$po" i || continue
      g_block "$rel" "content matched secret-assignment pattern"
    done < <(g_content_candidates "$src" "$po" "$only" i)
  fi
  rm -f "$ps" "$po"
}

# Full scan of a tree: paths + sizes + content
g_scan_tree() {
  local sha="$1" d names pairs revs
  g_tmp_init; d="$__g_tmp"; names="$d/names.$$"; pairs="$d/pairs.$$"; revs="$d/rev.$$"
  git ls-tree -r -l "$sha" 2>/dev/null | awk -F'\t' '{split($1,f," "); print f[3]"\t"$2}' > "$pairs" || { rm -f "$pairs"; return 0; }
  [ -s "$pairs" ] || { rm -f "$pairs"; return 0; }
  cut -f2 "$pairs" > "$names"
  g_scan_paths "$names"
  g_scan_sizes "$pairs"
  printf '%s\n' "$sha" > "$revs"
  g_scan_contents "$revs"
  rm -f "$names" "$pairs" "$revs"
}

# Index (staging area) scan: only newly staged additions/modifications
g_scan_index() {
  local d pairs names staged revs
  g_tmp_init; d="$__g_tmp"; pairs="$d/ipairs.$$"; names="$d/inames.$$"; staged="$d/staged.$$"
  git diff --cached --name-only --diff-filter=ACMR -z 2>/dev/null | tr '\0' '\n' | grep -v '^$' > "$staged"
  if [ ! -s "$staged" ]; then rm -f "$pairs" "$names" "$staged"; return 0; fi
  git ls-files -s -z 2>/dev/null | tr '\0' '\n' \
    | awk -F'\t' '{split($1,f," "); print f[2]"\t"$2}' \
    | awk -F'\t' 'NR==FNR { keep[$0]=1; next } ($2 in keep)' "$staged" - > "$pairs"
  [ -s "$pairs" ] || { rm -f "$pairs" "$names" "$staged"; return 0; }
  cut -f2 "$pairs" > "$names"
  g_scan_paths "$names"
  g_scan_sizes "$pairs"
  g_scan_contents index "$staged"
  rm -f "$pairs" "$names" "$staged"
}

# Scan every change in commits the server does not have yet (catches history added then removed)
g_scan_new_commits() {
  local tip="$1" d revs raw pairs names
  g_tmp_init; d="$__g_tmp"; revs="$d/nrevs.$$"; raw="$d/nraw.$$"; pairs="$d/npairs.$$"; names="$d/nnames.$$"
  git rev-list "$tip" --not --remotes 2>/dev/null > "$revs"
  if [ ! -s "$revs" ]; then rm -f "$revs"; return 0; fi
  git diff-tree --stdin --root -r --raw --no-abbrev --diff-filter=ACMR < "$revs" 2>/dev/null \
    | awk -F'\t' '/^:/{split($1,f," "); print f[4]"\t"$2}' | sort -u > "$pairs"
  if [ -s "$pairs" ]; then
    cut -f2 "$pairs" > "$names"
    g_scan_paths "$names"
    g_scan_sizes "$pairs"
  fi
  g_scan_contents "$revs"
  rm -f "$revs" "$raw" "$pairs" "$names"
}

guard_pre_commit() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
  g_tmp_init; trap 'g_tmpclean' EXIT
  if g_consume_one_shot "$top" "commit"; then
    printf '%s\n' "git-guard: bypass via notification, skipping this commit check" >&2
    exit 0
  fi
  g_check_repo_root "$top" || { g_report "commit"; exit 1; }
  g_scan_index
  g_check_fingerprints index
  if g_report "commit"; then
    g_notify_dismiss
  else
    return 1
  fi
}

guard_pre_push() {
  local top lref lsha rref rsha tips=() sha
  top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
  g_tmp_init; trap 'g_tmpclean' EXIT
  if g_consume_one_shot "$top" "push"; then
    printf '%s\n' "git-guard: bypass via notification, skipping this push check" >&2
    exit 0
  fi
  g_check_repo_root "$top" || { g_report "push"; exit 1; }
  while read -r lref lsha rref rsha; do
    [ -z "$lsha" ] && continue
    printf '%s' "$lsha" | grep -qE '^0+$' && continue
    tips+=("$lsha")
  done
  [ "${#tips[@]}" -eq 0 ] && exit 0
  for sha in $(printf '%s\n' "${tips[@]}" | sort -u); do
    g_scan_new_commits "$sha"
    g_scan_tree "$sha"
    g_check_fingerprints "$sha"
  done
  if g_report "push"; then
    g_notify_dismiss
  else
    return 1
  fi
}

# ============ Runtime private file fingerprint layer ============
# Only "private data": data/logs/instances dirs, *config*.json, credentials/secrets, databases, logs
# Source copies deployed to runtime (*.js/*.html/ui/*.json etc.) do not count, to avoid false positives
G_SENSITIVE_RE='(^|/)(data|logs?|instances|plugins-data|plugins-config|\.run)/'
G_SENSITIVE_RE="$G_SENSITIVE_RE"'|(^|/)(config(\.[A-Za-z0-9._-]+)?)\.json$'
G_SENSITIVE_RE="$G_SENSITIVE_RE"'|(^|/)\.env[^/]*$'
G_SENSITIVE_RE="$G_SENSITIVE_RE"'|\.(pem|p12|pfx|jks|keystore|kdbx|srl|key|db|sqlite3?|realm|log)$'
G_SENSITIVE_RE="$G_SENSITIVE_RE"'|(^|/)id_(rsa|ed25519)$'

g_fp_manifest() { printf '%s/private.blobs' "$GUARD_DIR"; }

# Build the fingerprint manifest: match by root-relative path (absolute paths may carry /data/ style prefixes that would falsely hit directory rules)
g_fp_snapshot() {
  local man d rels rels2 hashes root
  man=$(g_fp_manifest); g_tmp_init; d="$__g_tmp"
  rels="$d/rels.$$"; rels2="$d/rels2.$$"; hashes="$d/h.$$"
  : > "$man.tmp"
  while IFS= read -r root; do
    case "$root" in ''|'#'*) continue;; esac
    [ -d "$root" ] || continue
    (
      cd "$root" 2>/dev/null || exit 0
      find . \( -name .git -o -name node_modules -o -name .cache -o -name .cargo -o -name .npm -o -name .gradle -o -name .kotlin -o -name backups \) -prune -o \
        -type f -size +31c -size -5242881c -print 2>/dev/null | sed 's|^\./||' > "$rels"
      [ -s "$rels" ] || exit 0
      sed 's|^|/|' "$rels" | grep -E -- "$G_SENSITIVE_RE" | sed 's|^/||' > "$rels2"
      [ -s "$rels2" ] || exit 0
      git hash-object --stdin-paths < "$rels2" > "$hashes" 2>/dev/null
      paste "$hashes" <(sed "s|^|$root/|" "$rels2")
    ) >> "$man.tmp"
  done < "$GUARD_DIR/protected-roots.txt"
  sort -u -k1,1 "$man.tmp" > "$man"
  rm -f "$man.tmp" "$rels" "$rels2" "$hashes"
  echo "Fingerprint manifest updated: $man"
  echo "  $(wc -l < "$man") valid fingerprints (runtime private files only)"
}

# The fingerprint layer also honors allow-paths.txt (otherwise the unblock hints in reports would not work for fingerprints)
g_check_fingerprints() {
  local man ids d fp src id rel origin
  man=$(g_fp_manifest)
  [ -s "$man" ] || return 0
  g_tmp_init; d="$__g_tmp"; ids="$d/ids.$$"; fp="$d/fp.$$"
  cut -f1 "$man" | sort -u > "$ids"
  src="$1"
  if [ "$src" = "index" ]; then
    git ls-files -s -z 2>/dev/null | tr '\0' '\n' \
      | awk -F'\t' '{split($1,f," "); print f[2]"\t"$2}' > "$d/ls.$$"
  else
    git ls-tree -r "$src" 2>/dev/null | awk -F'\t' '{split($1,f," "); print f[3]"\t"$2}' > "$d/ls.$$"
  fi
  grep -Ff "$ids" "$d/ls.$$" > "$fp" 2>/dev/null || : > "$fp"
  while IFS=$'\t' read -r id rel; do
    [ -z "$id" ] && continue
    g_allowed_path "$rel" && continue
    origin=$(grep -m1 -F "$id"$'\t' "$man" | cut -f2)
    g_block "$rel" "content identical to a runtime file: ${origin/#$HOME/~}"
  done < "$fp"
  rm -f "$ids" "$fp" "$d/ls.$$"
}

# Content check for a single worktree file (used by git-guard check; index-free)
# $1=relative path (for allow-paths / skip rules)  $2=actual file path (defaults to $1)
g_check_content_file() {
  local rel="$1" f="${2:-$1}" d ps po top
  case "$f" in /*) top="$(git rev-parse --show-toplevel 2>/dev/null)";; esac
  if [ -n "${top:-}" ] && [ "${f#"$top"/}" != "$f" ]; then rel="${f#"$top"/}"; fi
  g_allowed_path "$rel" && return 0
  g_tmp_init; d="$__g_tmp"; ps="$d/fps.$$"; po="$d/fpo.$$"
  if [ -f "$GUARD_DIR/deny-content.txt" ]; then
    g_pats "$GUARD_DIR/deny-content.txt" > "$ps"
    if [ -s "$ps" ] && head -c "$GUARD_MAX_SCAN_BYTES" "$f" 2>/dev/null \
         | grep -avEi -- "$G_MOCK_RE" | grep -qaE -f "$ps"; then
      g_block "$rel" "content matched high-confidence secret pattern"; rm -f "$ps" "$po"; return 0
    fi
  fi
  if [ -f "$GUARD_DIR/deny-content-soft.txt" ] && ! g_skip_content_path "$rel"; then
    g_pats "$GUARD_DIR/deny-content-soft.txt" > "$po"
    if [ -s "$po" ] && head -c "$GUARD_MAX_SCAN_BYTES" "$f" 2>/dev/null \
         | grep -avEi -- "$G_MOCK_RE" | grep -qaEi -f "$po"; then
      g_block "$rel" "content matched secret-assignment pattern"; rm -f "$ps" "$po"; return 0
    fi
  fi
  rm -f "$ps" "$po"
}

# Fingerprint check for a single worktree file
# $1=relative path  $2=actual file path (defaults to $1)
g_check_fingerprint_file() {
  local rel="$1" f="${2:-$1}" man id origin
  man=$(g_fp_manifest)
  [ -s "$man" ] || return 0
  g_allowed_path "$rel" && return 0
  id=$(git hash-object "$f" 2>/dev/null) || return 0
  [ -n "$id" ] || return 0
  origin=$(grep -m1 -F "$id"$'\t' "$man" 2>/dev/null | cut -f2)
  [ -n "$origin" ] && g_block "$rel" "content identical to a runtime file: ${origin/#$HOME/~}"
  return 0
}
