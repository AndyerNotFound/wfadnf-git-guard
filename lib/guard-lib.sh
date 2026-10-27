#!/usr/bin/env bash
# git-guard 公共库：拦截"运行时隐私数据 / 密钥"进入 git
# 配置: ~/.config/git/guard/   临时放行: GUARD_OVERRIDE=1
GUARD_DIR="${GUARD_DIR:-$HOME/.config/git/guard}"
GUARD_MAX_FILE_BYTES="${GUARD_MAX_FILE_BYTES:-5242880}"
GUARD_MAX_SCAN_BYTES="${GUARD_MAX_SCAN_BYTES:-1048576}"
# 演示/占位值不算密钥
G_MOCK_RE='(mock|dummy|fake|sample|placeholder|example|redacted|your[_-]?(api|key|token)|xxx{3,}|1234567890abc|PUT-YOUR|xxxxx)'
# 只有"宽松"规则跳过的目录；高置信度规则任何目录都查
G_SKIP_RE='/(lang|locales|i18n|tests?|__tests__|fixtures|__mocks__|docs?|examples?)/'

__g_blocked=0; __g_files=(); __g_reasons=()

g_block() {
  local x
  for x in "${__g_files[@]:-}"; do [ "$x" = "$1" ] && return 0; done
  __g_blocked=1; __g_files+=("$1"); __g_reasons+=("$2")
}

g_pats() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null; }

g_report() {
  [ "$__g_blocked" -eq 0 ] && return 0
  {
    printf '\n============ git-guard 已拦截%s ============\n' "$1"
    local i
    for i in "${!__g_files[@]}"; do
      printf '  x %s\n      -> %s\n' "${__g_files[$i]}" "${__g_reasons[$i]}"
    done
    printf '%s\n' "---------------------------------------------------------"
    printf '%s\n' "通常是运行时数据/密钥/配置被 add 进来了。处理办法："
    printf '%s\n' "  git restore --staged <file>        # 取消暂存"
    printf '%s\n' "  git rm --cached <file>             # 已入库的移出索引"
    printf '%s\n' "  echo '<pattern>' >> .gitignore     # 长期忽略"
    printf '%s\n' "规则: ~/.config/git/guard/{deny-paths,deny-content,deny-content-soft}.txt"
    printf '%s\n' "误伤可加到 allow-paths.txt；确认无害才: GUARD_OVERRIDE=1 git ..."
    printf '%s\n' "========================================================="
  } >&2
  [ "${GUARD_OVERRIDE:-0}" = "1" ] && { printf '%s\n' "git-guard: GUARD_OVERRIDE=1，本次放行" >&2; return 0; }
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
        g_block "$top" "该仓库位于受保护的运行时目录 $root 内，默认禁止提交/推送"
        return 1;;
    esac
  done < "$GUARD_DIR/protected-roots.txt"
  return 0
}

g_allowed_path() {
  [ -f "$GUARD_DIR/allow-paths.txt" ] || return 1
  printf '/%s' "$1" | grep -qE -f <(g_pats "$GUARD_DIR/allow-paths.txt")
}

g_check_path() {
  local rel="$1" pat
  [ -f "$GUARD_DIR/deny-paths.txt" ] || return 0
  g_allowed_path "$rel" && return 0
  while IFS= read -r pat; do
    case "$pat" in ''|'#'*) continue;; esac
    if printf '/%s' "$rel" | grep -qE -- "$pat"; then
      g_block "$rel" "路径命中禁止规则: $pat"; return 0
    fi
  done < "$GUARD_DIR/deny-paths.txt"
}

g_check_size() {
  [ -z "${2:-}" ] && return 0
  [ "$2" -gt "$GUARD_MAX_FILE_BYTES" ] && { g_block "$1" "文件过大(${2} 字节)，疑似数据库/备份/构建产物"; return 0; }
  return 0
}

g_skip_content_path() { printf '/%s' "$1" | grep -qE "$G_SKIP_RE"; }

# 内容检查：$1=相对路径  $2=blob 表达式（":path" 或 "<sha>:path"）
# 高置信度规则大小写敏感、任何目录都查（含二进制）；宽松规则 lang/test/docs 跳过
g_check_content_blob() {
  local rel="$1" spec="$2" ps="$TMPDIR/gg.s.$$" po="$TMPDIR/gg.o.$$"
  g_allowed_path "$rel" && return 0
  if [ -f "$GUARD_DIR/deny-content.txt" ]; then
    g_pats "$GUARD_DIR/deny-content.txt" > "$ps"
    if [ -s "$ps" ] && git cat-file -p "$spec" 2>/dev/null | head -c "$GUARD_MAX_SCAN_BYTES" \
         | grep -vaEi -- "$G_MOCK_RE" | grep -qaE -f "$ps"; then
      g_block "$rel" "内容命中高置信度密钥特征"; rm -f "$ps" "$po"; return 0
    fi
  fi
  if [ -f "$GUARD_DIR/deny-content-soft.txt" ] && ! g_skip_content_path "$rel"; then
    g_pats "$GUARD_DIR/deny-content-soft.txt" > "$po"
    if [ -s "$po" ] && git cat-file -p "$spec" 2>/dev/null | head -c "$GUARD_MAX_SCAN_BYTES" \
         | grep -vaEi -- "$G_MOCK_RE" | grep -qaEi -f "$po"; then
      g_block "$rel" "内容命中密钥赋值特征"; rm -f "$ps" "$po"; return 0
    fi
  fi
  rm -f "$ps" "$po"
}

g_check_content() { g_check_content_blob "$1" ":$1"; }

# 全量扫描某棵树：路径 + 体积 + 内容（内容用单次 git grep，避免逐文件 fork）
g_scan_tree() {
  local sha="$1" pp="$TMPDIR/gg.pp.$$" ps="$TMPDIR/gg.ps.$$" po="$TMPDIR/gg.po.$$" tree="$TMPDIR/gg.tree.$$" rel
  git ls-tree -r -l "$sha" > "$tree" 2>/dev/null || { rm -f "$tree"; return 0; }
  g_pats "$GUARD_DIR/deny-paths.txt"        > "$pp"
  g_pats "$GUARD_DIR/deny-content.txt"      > "$ps"
  g_pats "$GUARD_DIR/deny-content-soft.txt" > "$po"

  while IFS= read -r rel; do
    g_block "$rel" "文件过大，疑似数据库/备份/构建产物"
  done < <(awk -F'\t' -v max="$GUARD_MAX_FILE_BYTES" '{n=split($1,a," "); if (a[4]+0>max) print $2}' "$tree")

  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    g_allowed_path "$rel" && continue
    g_block "$rel" "路径命中禁止规则"
  done < <(awk -F'\t' '{print "/" $2}' "$tree" | grep -aE -f "$pp" 2>/dev/null | sed 's|^/||')

  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    g_allowed_path "$rel" && continue
    g_block "$rel" "内容命中高置信度密钥特征"
  done < <(git grep -I -n -E -f "$ps" "$sha" -- . 2>/dev/null \
             | grep -avE -- "$G_MOCK_RE" | awk -F: '{print $2}' | sort -u)

  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    g_allowed_path "$rel" && continue
    g_skip_content_path "$rel" && continue
    g_block "$rel" "内容命中密钥赋值特征"
  done < <(git grep -I -n -E -f "$po" "$sha" -- . 2>/dev/null \
             | grep -avEi -- "$G_MOCK_RE" | awk -F: '{print $2}' | sort -u)

  rm -f "$pp" "$ps" "$po" "$tree"
}

# 扫描"服务器上还没有的提交"的每一处改动（拦住加进去又删掉的历史）
g_scan_new_commits() {
  local tip="$1" c rel
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    while IFS= read -r rel; do
      [ -z "$rel" ] && continue
      g_check_path "$rel"
      g_check_size "$rel" "$(git cat-file -s "$c:$rel" 2>/dev/null)"
      g_check_content_blob "$rel" "$c:$rel"
    done < <(git diff-tree --root --no-commit-id --name-only -r --diff-filter=ACMR "$c" 2>/dev/null)
  done < <(git rev-list "$tip" --not --remotes 2>/dev/null)
}

guard_pre_commit() {
  local top f
  top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
  g_check_repo_root "$top" || { g_report "提交"; exit 1; }
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    g_check_path "$f"
    g_check_size "$f" "$(git cat-file -s ":$f" 2>/dev/null)"
    g_check_content "$f"
  done < <(git diff --cached --name-only --diff-filter=ACMR -z | tr '\0' '\n')
  g_check_fingerprints index
  g_report "提交"
}

guard_pre_push() {
  local top lref lsha rref rsha tips=() sha
  top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
  g_check_repo_root "$top" || { g_report "推送"; exit 1; }
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
  g_report "推送"
}

# ============ 运行时私有文件指纹层 ============
# 只收"私有数据"：data/logs/instances 目录、*config*.json、口令与密钥、数据库、日志
# 部署到运行时的源码副本（*.js/*.html/ui/*.json 等）不算，避免误报
G_SENSITIVE_RE='(^|/)(data|logs?|instances|plugins-data|plugins-config|\.run)/'
G_SENSITIVE_RE="$G_SENSITIVE_RE"'|(^|/)(config(\.[A-Za-z0-9._-]+)?)\.json$'
G_SENSITIVE_RE="$G_SENSITIVE_RE"'|(^|/)\.env[^/]*$'
G_SENSITIVE_RE="$G_SENSITIVE_RE"'|\.(pem|p12|pfx|jks|keystore|kdbx|srl|key|db|sqlite3?|realm|log)$'
G_SENSITIVE_RE="$G_SENSITIVE_RE"'|(^|/)id_(rsa|ed25519)$'

g_fp_manifest() { printf '%s/private.blobs' "$GUARD_DIR"; }

# 生成指纹清单：按"相对根路径"匹配（绝对路径可能自带 /data/ 之类前缀，会误命中目录规则）
g_fp_snapshot() {
  local man; man=$(g_fp_manifest)
  local root rels="$TMPDIR/gg.rels.$$" rels2="$TMPDIR/gg.rels2.$$" hashes="$TMPDIR/gg.h.$$"
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
  echo "指纹清单已更新: $man"
  echo "  有效指纹 $(wc -l < "$man") 条（只含运行时私有文件）"
}

g_check_fingerprints() {
  local man ids; man=$(g_fp_manifest)
  [ -s "$man" ] || return 0
  ids="$TMPDIR/gg.ids.$$"; cut -f1 "$man" | sort -u > "$ids"
  local src="$1" id rel origin
  if [ "$src" = "index" ]; then
    while IFS=$'\t' read -r id rel; do
      origin=$(grep -m1 -F "$id"$'\t' "$man" | cut -f2)
      g_block "$rel" "内容与运行时文件完全相同: ${origin/#$HOME/~}"
    done < <(git ls-files -s 2>/dev/null | awk '{id=$2; sub(/^[^\t]*\t/,""); print id"\t"$0}' | grep -Ff "$ids")
  else
    while IFS=$'\t' read -r id rel; do
      origin=$(grep -m1 -F "$id"$'\t' "$man" | cut -f2)
      g_block "$rel" "内容与运行时文件完全相同: ${origin/#$HOME/~}"
    done < <(git ls-tree -r "$src" 2>/dev/null | awk '{id=$3; sub(/^[^\t]*\t/,""); print id"\t"$0}' | grep -Ff "$ids")
  fi
  rm -f "$ids"
}
