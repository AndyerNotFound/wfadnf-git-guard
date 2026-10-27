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

# TMPDIR 兜底：cron/CI 里常未设置，缺失会让临时文件写入失败、检查静默失效。
# 依次探测可写目录（Android/Termux 上 /tmp 往往不可写，所以不能只回退 /tmp）。
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
  printf '%s\n' "git-guard: 找不到可写的临时目录，无法执行检查（不会静默放行）" >&2
  printf '%s\n' "  设置 TMPDIR 到可写目录后重试，或确认无害后: GUARD_OVERRIDE=1 git ..." >&2
  [ "${GUARD_OVERRIDE:-0}" = "1" ] && TMPDIR="$HOME" || exit 1
fi
export TMPDIR

__g_blocked=0; __g_files=(); __g_reasons=()
__g_tmp=""

# 本次进程专用临时目录：显式初始化（不能用命令替换，否则赋值只发生在子 shell 里，
# 每次调用都会新建目录并泄漏）。结果放在全局 $__g_tmp。
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

# ============ 通知层 ============
# 被拦时推送到系统通知栏，省掉"回 Termux 敲命令"这一步。
# 通知本身失败绝不影响拦截结果（全部 || :，并带 timeout）。
G_NOTIFY_TITLE_PREFIX="${GUARD_NOTIFY_TITLE_PREFIX:-git-guard}"

# 是否启用：GUARD_NOTIFY=0 关；$GUARD_DIR/notify.off 关；没有可用通知命令则静默跳过
g_notify_enabled() {
  [ "${GUARD_NOTIFY:-1}" = "0" ] && return 1
  [ -f "$GUARD_DIR/notify.off" ] && return 1
  command -v termux-notification >/dev/null 2>&1 && return 0
  command -v notify-send >/dev/null 2>&1 && return 0
  return 1
}

# 写拦截报告：通知里点"详情"打开的就是它
# 一次性放行令牌：通知"本次允许"按钮写入；绑定仓库+操作类型，带过期时间，
# 下一次同仓库同操作时消费掉（等价于 GUARD_OVERRIDE=1，但只能用一次）
g_one_shot_file() { printf '%s/override-one-shot' "$GUARD_DIR"; }

# $1=仓库根  $2=操作类型（提交/推送）；命中则消费令牌并返回 0
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

# 检查通过后撤销之前的拦截通知（只在上次真的拦截过时才有开销）
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
    printf '%s\n' "git restore --staged <file>      取消暂存"
    printf '%s\n' "git rm --cached <file>           已入库的移出索引"
    printf '%s\n' "echo '<pattern>' >> .gitignore   长期忽略"
    printf '%s\n' ""
    printf '规则: %s/{deny-paths,deny-content,deny-content-soft}.txt\n' "$GUARD_DIR"
    printf '误伤放行: echo '\''^/路径$'\'' >> %s/allow-paths.txt\n' "$GUARD_DIR"
    printf '单次放行: GUARD_OVERRIDE=1 git ...\n'
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
  title="$G_NOTIFY_TITLE_PREFIX 拦截${kind} · $rb · ${n} 个文件"
  body=""
  i=0
  while [ "$i" -lt "$n" ] && [ "$i" -lt 5 ]; do
    body="$body${__g_files[$i]} — ${__g_reasons[$i]}"$'\n'
    i=$((i + 1))
  done
  [ "$n" -gt 5 ] && body="$body… 另有 $((n - 5)) 个文件"$'\n'
  body="$body（点"详情"看完整报告）"
  act="$GUARD_DIR/notify-action.sh"

  if command -v termux-notification >/dev/null 2>&1; then
    if [ -x "$act" ]; then
      timeout 8 termux-notification --title "$title" --content "$body" \
        --priority high --id git-guard --sound \
        --button1 "取消暂存" --button1-action "$act undo" \
        --button2 "本次允许" --button2-action "$act allow" \
        --button3 "详情" --button3-action "$act view" \
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
        g_block "$top" "该仓库位于受保护的运行时目录 $root 内，默认禁止提交/推送"
        return 1;;
    esac
  done < "$GUARD_DIR/protected-roots.txt"
  return 0
}

g_allowed_path() {
  [ -f "$GUARD_DIR/allow-paths.txt" ] || return 1
  printf '/%s' "$1" | grep -qE -f <(g_pats "$GUARD_DIR/allow-paths.txt") 2>/dev/null
}

# 单个路径检查：命中时才逐条定位是哪条规则（规则条数少，且只对已命中的路径做）
g_check_path() {
  local rel="$1" pp pat
  [ -f "$GUARD_DIR/deny-paths.txt" ] || return 0
  g_allowed_path "$rel" && return 0
  g_tmp_init; pp="$__g_tmp/pp.$$"
  g_pats "$GUARD_DIR/deny-paths.txt" > "$pp"
  if [ ! -s "$pp" ]; then rm -f "$pp"; return 0; fi
  # 一次判断是否命中，未命中直接返回（绝大多数文件走这条快路径）
  if ! printf '/%s' "$rel" | grep -qE -f "$pp" 2>/dev/null; then rm -f "$pp"; return 0; fi
  while IFS= read -r pat; do
    case "$pat" in ''|'#'*) continue;; esac
    if printf '/%s' "$rel" | grep -qE -- "$pat" 2>/dev/null; then
      g_block "$rel" "路径命中禁止规则: $pat"; rm -f "$pp"; return 0
    fi
  done < "$pp"
  g_block "$rel" "路径命中禁止规则"; rm -f "$pp"
}

g_check_size() {
  [ -z "${2:-}" ] && return 0
  [ "$2" -gt "$GUARD_MAX_FILE_BYTES" ] && { g_block "$1" "文件过大(${2} 字节)，疑似数据库/备份/构建产物"; return 0; }
  return 0
}

g_skip_content_path() { printf '/%s' "$1" | grep -qE "$G_SKIP_RE"; }

# 单个 blob 判定：截断到 MAX_SCAN_BYTES + 过滤占位值 + 规则匹配；$3 = i 表示忽略大小写
g_blob_match() {
  git cat-file -p "$1" 2>/dev/null | head -c "$GUARD_MAX_SCAN_BYTES" \
    | grep -avEi -- "$G_MOCK_RE" | grep -qa"${3:-}"E -f "$2"
}

# 内容检查：$1=相对路径  $2=blob 表达式（":path" 或 "<sha>:path"）
g_check_content_blob() {
  local rel="$1" spec="$2" d ps po
  g_allowed_path "$rel" && return 0
  g_tmp_init; d="$__g_tmp"; ps="$d/ps.$$"; po="$d/po.$$"
  if [ -f "$GUARD_DIR/deny-content.txt" ]; then
    g_pats "$GUARD_DIR/deny-content.txt" > "$ps"
    if [ -s "$ps" ] && g_blob_match "$spec" "$ps"; then
      g_block "$rel" "内容命中高置信度密钥特征"; rm -f "$ps" "$po"; return 0
    fi
  fi
  if [ -f "$GUARD_DIR/deny-content-soft.txt" ] && ! g_skip_content_path "$rel"; then
    g_pats "$GUARD_DIR/deny-content-soft.txt" > "$po"
    if [ -s "$po" ] && g_blob_match "$spec" "$po" i; then
      g_block "$rel" "内容命中密钥赋值特征"; rm -f "$ps" "$po"; return 0
    fi
  fi
  rm -f "$ps" "$po"
}

g_check_content() { g_check_content_blob "$1" ":$1"; }

# ---- 批量层：一次 fork 处理整个索引/整棵树 ----

# 路径层：$1 = 候选路径清单
g_scan_paths() {
  local list="$1" d pp
  [ -s "$list" ] || return 0
  [ -f "$GUARD_DIR/deny-paths.txt" ] || return 0
  g_tmp_init; d="$__g_tmp"; pp="$d/bpp.$$"
  g_pats "$GUARD_DIR/deny-paths.txt" > "$pp"
  if [ -s "$pp" ]; then
    # 先用一次 grep 缩小到真正命中的少数路径，再逐条定位规则
    sed 's|^|/|' "$list" | grep -aE -f "$pp" 2>/dev/null | sed 's|^/||' > "$d/hit.$$"
    while IFS= read -r p; do
      [ -n "$p" ] && g_check_path "$p"
    done < "$d/hit.$$"
    rm -f "$d/hit.$$"
  fi
  rm -f "$pp"
}

# 体积层：$1 = "sha<TAB>path"；一次 batch-check 取全部大小
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

# 内容层候选：$1 = index | <rev 清单文件>；$2 = 规则文件；$3 = 可选，只保留这些路径
# 输出 "blob 表达式<TAB>路径"，表达式可直接喂 git cat-file
g_content_candidates() {
  local src="$1" pats="$2" only="${3:-}" ci="${4:-}" d raw
  g_tmp_init; d="$__g_tmp"; raw="$d/cand.$$"
  : > "$raw"
  if [ "$src" = "index" ]; then
    git grep --cached -a -l -z -E ${ci:+-i} -f "$pats" 2>/dev/null | tr '\0' '\n' \
      | while IFS= read -r p; do [ -n "$p" ] && printf ':%s\t%s\n' "$p" "$p"; done > "$raw"
  else
    [ -s "$src" ] || return 0
    # 分块传 rev，避免大推送时撞上命令行参数长度上限
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

# 内容层：$1 = index | <rev 清单文件>；$2 = 可选，只查这些路径
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
      g_block "$rel" "内容命中高置信度密钥特征"
    done < <(g_content_candidates "$src" "$ps" "$only")
  fi

  if [ -s "$po" ]; then
    while IFS=$'\t' read -r spec rel; do
      [ -z "$rel" ] && continue
      g_allowed_path "$rel" && continue
      g_skip_content_path "$rel" && continue
      g_blob_match "$spec" "$po" i || continue
      g_block "$rel" "内容命中密钥赋值特征"
    done < <(g_content_candidates "$src" "$po" "$only" i)
  fi
  rm -f "$ps" "$po"
}

# 全量扫描某棵树：路径 + 体积 + 内容
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

# 索引（暂存区）扫描：只查本次暂存的新增/修改
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

# 扫描"服务器上还没有的提交"的每一处改动（拦住加进去又删掉的历史）
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
  if g_consume_one_shot "$top" "提交"; then
    printf '%s\n' "git-guard: 通知放行，跳过本次提交检查" >&2
    exit 0
  fi
  g_check_repo_root "$top" || { g_report "提交"; exit 1; }
  g_scan_index
  g_check_fingerprints index
  if g_report "提交"; then
    g_notify_dismiss
  else
    return 1
  fi
}

guard_pre_push() {
  local top lref lsha rref rsha tips=() sha
  top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
  g_tmp_init; trap 'g_tmpclean' EXIT
  if g_consume_one_shot "$top" "推送"; then
    printf '%s\n' "git-guard: 通知放行，跳过本次推送检查" >&2
    exit 0
  fi
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
  if g_report "推送"; then
    g_notify_dismiss
  else
    return 1
  fi
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
  echo "指纹清单已更新: $man"
  echo "  有效指纹 $(wc -l < "$man") 条（只含运行时私有文件）"
}

# 指纹层同样尊重 allow-paths.txt（否则报告里提示的放行办法对指纹无效）
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
    g_block "$rel" "内容与运行时文件完全相同: ${origin/#$HOME/~}"
  done < "$fp"
  rm -f "$ids" "$fp" "$d/ls.$$"
}

# 单个工作区文件的内容检查（供 git-guard check 使用，不依赖 index）
# $1=相对路径（用于 allow-paths / 跳过规则）  $2=实际文件路径（缺省同 $1）
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
      g_block "$rel" "内容命中高置信度密钥特征"; rm -f "$ps" "$po"; return 0
    fi
  fi
  if [ -f "$GUARD_DIR/deny-content-soft.txt" ] && ! g_skip_content_path "$rel"; then
    g_pats "$GUARD_DIR/deny-content-soft.txt" > "$po"
    if [ -s "$po" ] && head -c "$GUARD_MAX_SCAN_BYTES" "$f" 2>/dev/null \
         | grep -avEi -- "$G_MOCK_RE" | grep -qaEi -f "$po"; then
      g_block "$rel" "内容命中密钥赋值特征"; rm -f "$ps" "$po"; return 0
    fi
  fi
  rm -f "$ps" "$po"
}

# 单个工作区文件的指纹检查
# $1=相对路径  $2=实际文件路径（缺省同 $1）
g_check_fingerprint_file() {
  local rel="$1" f="${2:-$1}" man id origin
  man=$(g_fp_manifest)
  [ -s "$man" ] || return 0
  g_allowed_path "$rel" && return 0
  id=$(git hash-object "$f" 2>/dev/null) || return 0
  [ -n "$id" ] || return 0
  origin=$(grep -m1 -F "$id"$'\t' "$man" 2>/dev/null | cut -f2)
  [ -n "$origin" ] && g_block "$rel" "内容与运行时文件完全相同: ${origin/#$HOME/~}"
  return 0
}
