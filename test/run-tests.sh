#!/usr/bin/env bash
# 自测：全部在临时目录里跑，不碰真实 $HOME
set -uo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GUARD_ROOT="$T/root" GUARD_DIR="$T/root/guard"
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

echo
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ]
