#!/usr/bin/env bash
# 自测：全部在临时目录里跑，不碰真实 $HOME
set -uo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GUARD_ROOT="$T/root" GUARD_DIR="$T/root/guard"
# 自测不往手机上推真实通知
export GUARD_NOTIFY=0
mkdir -p "$GUARD_ROOT/template/hooks" "$GUARD_ROOT/template/info" "$GUARD_DIR"
cp "$SRC/lib/guard-lib.sh" "$GUARD_ROOT/"
cp "$SRC"/share/template/hooks/* "$GUARD_ROOT/template/hooks/"
cp "$SRC/share/template/info/exclude" "$GUARD_ROOT/template/info/"
cp "$SRC"/share/guard/*.txt "$GUARD_DIR/"
chmod +x "$GUARD_ROOT/template/hooks/"*

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# 造一个"运行时"目录并生成指纹
RT="$T/runtime"; mkdir -p "$RT/data"
printf '{"channels":[{"key":"9f3a7b2c1d8e4f6a0b5c9d2e"}]}' > "$RT/data/config.Prod.json"
printf 'secret-token-abcdefghijklmnop\n' > "$RT/data/.sessionkey"
echo "$RT" > "$GUARD_DIR/protected-roots.txt"
bash -c ". '$GUARD_ROOT/guard-lib.sh'; g_fp_snapshot" >/dev/null

new_repo(){
  local d="$T/$1"; rm -rf "$d"; mkdir -p "$d"; cd "$d"
  git init -q .; git config user.email t@t; git config user.name t
  cp "$GUARD_ROOT/template/hooks/"* .git/hooks/; chmod +x .git/hooks/*
  echo base > base.txt; git add base.txt; git commit -qm base >/dev/null 2>&1
}
blocked(){ git add -A >/dev/null 2>&1; git commit -qm x >/dev/null 2>&1; [ $? -ne 0 ]; }
passed(){ git add -A >/dev/null 2>&1; git commit -qm x >/dev/null 2>&1; [ $? -eq 0 ]; }
reset_repo(){ cd "$T/${1:-r}"; git reset -q --hard HEAD >/dev/null 2>&1; git clean -qfd; }

echo "== 提交层 =="
new_repo r
echo 'const a=1' > a.js; passed && ok "普通代码放行" || no "普通代码放行"
reset_repo r
mkdir -p data; echo '{}' > data/cfg.json
blocked && ok "根 data/ 拦截" || no "根 data/ 拦截"; reset_repo r
mkdir -p app/data; cp "$RT/data/config.Prod.json" app/data/x.json
blocked && ok "嵌套 app/data/ 拦截" || no "嵌套 app/data/ 拦截"; reset_repo r
mkdir -p test; cp "$RT/data/config.Prod.json" test/fx.json
blocked && ok "test/ 内真实私有文件拦截" || no "test/ 内真实私有文件拦截"; reset_repo r
cp "$RT/data/config.Prod.json" notes.dat
blocked && ok "改名 .dat（指纹）拦截" || no "改名 .dat（指纹）拦截"; reset_repo r
printf 'const k="sk-%s";\n' "abcdefghijklmnopqrstuvwx" > k.js
blocked && ok "手写密钥拦截" || no "手写密钥拦截"; reset_repo r
printf '{"channels":[{"key":"9f3a7b2c1d8e4f6a0b5c9d2e"}]}' > ch.json
blocked && ok "字段名 key 拦截" || no "字段名 key 拦截"; reset_repo r
mkdir -p app/src/main/java/com/x/data; echo 'class A{}' > app/src/main/java/com/x/data/A.kt
passed && ok "源码 data 包放行" || no "源码 data 包放行"; reset_repo r
head -c 6000000 /dev/zero | tr '\0' 'a' > big.txt
blocked && ok "6MB 文件拦截" || no "6MB 文件拦截"; reset_repo r

echo "== 推送层 =="
new_repo p; git init -q --bare "$T/bare.git"; git remote add origin "$T/bare.git"
mkdir -p data; cp "$RT/data/config.Prod.json" data/c.json
git add -f data >/dev/null 2>&1; git commit -qm leak --no-verify >/dev/null 2>&1
git push -q origin HEAD:main >/dev/null 2>&1; [ $? -ne 0 ] && ok "--no-verify 后推送被拦" || no "--no-verify 后推送被拦"

new_repo m; git init -q --bare "$T/bare2.git"; git remote add origin "$T/bare2.git"
git checkout -qb br; mkdir -p data; cp "$RT/data/config.Prod.json" data/c.json
git add -f data >/dev/null 2>&1; git commit -qm leak --no-verify >/dev/null 2>&1
git checkout -q master 2>/dev/null || git checkout -q main
echo m > m.txt; git add m.txt; git commit -qm m >/dev/null 2>&1
git merge br --no-edit >/dev/null 2>&1
git push -q origin HEAD:main >/dev/null 2>&1; [ $? -ne 0 ] && ok "merge 带入 data 被拦" || no "merge 带入 data 被拦"

echo "== 受保护目录 =="
mkdir -p "$RT/repo"; cd "$RT/repo"; git init -q .; git config user.email t@t; git config user.name t
cp "$GUARD_ROOT/template/hooks/"* .git/hooks/
echo x > a.txt; git add a.txt; git commit -qm x >/dev/null 2>&1
[ $? -ne 0 ] && ok "受保护目录内禁止提交" || no "受保护目录内禁止提交"

echo "== 二进制与放行 =="
new_repo b1
printf '\000\001sk-%s\000\377\n' "abcdefghijklmnopqrstuvwx" > blob.bin
blocked && ok "二进制内嵌密钥拦截" || no "二进制内嵌密钥拦截"; reset_repo b1
new_repo b2
printf 'const k="sk-%s";\n' "abcdefghijklmnopqrstuvwx" > k.js
GUARD_OVERRIDE=1 git add -A >/dev/null 2>&1
GUARD_OVERRIDE=1 git commit -qm x >/dev/null 2>&1
[ $? -eq 0 ] && ok "GUARD_OVERRIDE 单次放行" || no "GUARD_OVERRIDE 单次放行"; reset_repo b2
new_repo b3
mkdir -p fixtures; printf 'const k="sk-%s";\n' "abcdefghijklmnopqrstuvwx" > fixtures/k.js
echo '^/fixtures/' >> "$GUARD_DIR/allow-paths.txt"
passed && ok "allow-paths 放行" || no "allow-paths 放行"
sed -i '$d' "$GUARD_DIR/allow-paths.txt"; reset_repo b3

echo "== 临时目录兜底 =="
new_repo t1
mkdir -p data; echo '{}' > data/c.json
git add -f data >/dev/null 2>&1
env -u TMPDIR bash -c '. "$GUARD_ROOT/guard-lib.sh"; guard_pre_commit' >/dev/null 2>&1
[ $? -ne 0 ] && ok "无 TMPDIR 仍能拦截" || no "无 TMPDIR 仍能拦截"; reset_repo t1
rm -rf "$TMPDIR"/gg.* 2>/dev/null
bash -c '. "$GUARD_ROOT/guard-lib.sh"; g_tmp_init; g_tmpclean' >/dev/null 2>&1
[ "$(ls -d "$TMPDIR"/gg.* 2>/dev/null | wc -l)" -eq 0 ] && ok "临时目录不残留" || no "临时目录不残留"

echo "== 推送层二进制 =="
new_repo p2; git init -q --bare "$T/bare3.git"; git remote add origin "$T/bare3.git"
printf '\000sk-%s\000\n' "abcdefghijklmnopqrstuvwx" > blob.bin
git add -A >/dev/null 2>&1; git commit -qm leak --no-verify >/dev/null 2>&1
git push -q origin HEAD:master >/dev/null 2>&1
[ $? -ne 0 ] && ok "推送层拦二进制密钥" || no "推送层拦二进制密钥"

echo "== wsnap =="
WS="$T/ws"; mkdir -p "$WS/sub"; echo a > "$WS/a.txt"; echo b > "$WS/sub/b.txt"
run_wsnap(){ WSN_ROOT="$WS" WSN_STATE="$GUARD_DIR/wsnap" "$SRC/bin/wsnap" "$@" 2>&1; }
run_wsnap init >/dev/null
run_wsnap verify | grep -q "0 新增 / 0 修改 / 0 删除" && ok "wsnap 基线无变化" || no "wsnap 基线无变化"
echo c > "$WS/c.txt"
run_wsnap verify | grep -q "1 新增" && ok "wsnap 检出新增" || no "wsnap 检出新增"
mkdir -p "$WS/data"; echo '{}' > "$WS/data/x.json"
run_wsnap verify >/dev/null 2>&1; [ $? -eq 3 ] && ok "wsnap 可疑路径返回 3" || no "wsnap 可疑路径返回 3"
run_wsnap verify --accept >/dev/null 2>&1
run_wsnap verify >/dev/null 2>&1; [ $? -eq 0 ] && ok "wsnap --accept 生效" || no "wsnap --accept 生效"

echo "== 通知层 =="
new_repo n1
mkdir -p data; echo '{}' > data/c.json
git add -f data >/dev/null 2>&1
GUARD_NOTIFY=1 git commit -qm x >/dev/null 2>&1
[ -s "$GUARD_DIR/last-block.txt" ] && ok "拦截时写报告文件" || no "拦截时写报告文件"
grep -q "^REPO=" "$GUARD_DIR/last-block.txt" 2>/dev/null \
  && grep -q "data/c.json" "$GUARD_DIR/last-block.txt" 2>/dev/null \
  && ok "报告含仓库与命中文件" || no "报告含仓库与命中文件"
# 通知关闭时不应写报告（GUARD_NOTIFY=0 走的是"未启用"分支，报告仍在 g_notify 内）
rm -f "$GUARD_DIR/last-block.txt"
GUARD_NOTIFY=0 git commit -qm y >/dev/null 2>&1
[ ! -s "$GUARD_DIR/last-block.txt" ] && ok "GUARD_NOTIFY=0 不写报告" || no "GUARD_NOTIFY=0 不写报告"
touch "$GUARD_DIR/notify.off"
GUARD_NOTIFY=1 git commit -qm z >/dev/null 2>&1
[ ! -s "$GUARD_DIR/last-block.txt" ] && ok "notify.off 关闭通知" || no "notify.off 关闭通知"
rm -f "$GUARD_DIR/notify.off"; reset_repo n1

echo "== 通知按钮：本次允许 =="
new_repo a1
mkdir -p data; echo '{}' > data/c.json
git add -f data >/dev/null 2>&1
git commit -qm x >/dev/null 2>&1
[ $? -ne 0 ] && ok "放行前被拦" || no "放行前被拦"
printf 'REPO=%s\nKIND=提交\nEXPIRE=%s\n' "$PWD" "$(( $(date +%s) + 600 ))" > "$GUARD_DIR/override-one-shot"
git commit -qm x >/dev/null 2>&1
[ $? -eq 0 ] && ok "令牌放行一次" || no "令牌放行一次"
[ ! -e "$GUARD_DIR/override-one-shot" ] && ok "令牌用后即焚" || no "令牌用后即焚"
mkdir -p data; echo y > data/y.json; git add -f data >/dev/null 2>&1
git commit -qm x >/dev/null 2>&1
[ $? -ne 0 ] && ok "令牌用完再拦" || no "令牌用完再拦"
reset_repo a1
new_repo a2
mkdir -p data; echo '{}' > data/c.json; git add -f data >/dev/null 2>&1
printf 'REPO=%s\nKIND=提交\nEXPIRE=%s\n' "$PWD" "$(( $(date +%s) - 10 ))" > "$GUARD_DIR/override-one-shot"
git commit -qm x >/dev/null 2>&1
[ $? -ne 0 ] && ok "过期令牌不放行" || no "过期令牌不放行"
[ ! -e "$GUARD_DIR/override-one-shot" ] && ok "过期令牌也被消费" || no "过期令牌也被消费"
reset_repo a2

echo
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ]
