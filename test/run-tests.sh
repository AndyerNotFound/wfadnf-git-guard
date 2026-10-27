#!/usr/bin/env bash
# Self-test: runs entirely in a temp dir, never touches the real $HOME
set -uo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GUARD_ROOT="$T/root" GUARD_DIR="$T/root/guard"
# Self-test must not push real notifications to the phone
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

# Create a fake "runtime" dir and generate fingerprints
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

echo "== Commit layer =="
new_repo r
echo 'const a=1' > a.js; passed && ok "plain code passes" || no "plain code passes"
reset_repo r
mkdir -p data; echo '{}' > data/cfg.json
blocked && ok "root data/ blocked" || no "root data/ blocked"; reset_repo r
mkdir -p app/data; cp "$RT/data/config.Prod.json" app/data/x.json
blocked && ok "nested app/data/ blocked" || no "nested app/data/ blocked"; reset_repo r
mkdir -p test; cp "$RT/data/config.Prod.json" test/fx.json
blocked && ok "real private file inside test/ blocked" || no "real private file inside test/ blocked"; reset_repo r
cp "$RT/data/config.Prod.json" notes.dat
blocked && ok "renamed .dat blocked (fingerprint)" || no "renamed .dat blocked (fingerprint)"; reset_repo r
printf 'const k="sk-%s";\n' "abcdefghijklmnopqrstuvwx" > k.js
blocked && ok "handwritten secret blocked" || no "handwritten secret blocked"; reset_repo r
printf '{"channels":[{"key":"9f3a7b2c1d8e4f6a0b5c9d2e"}]}' > ch.json
blocked && ok "key field name blocked" || no "key field name blocked"; reset_repo r
mkdir -p app/src/main/java/com/x/data; echo 'class A{}' > app/src/main/java/com/x/data/A.kt
passed && ok "source data package passes" || no "source data package passes"; reset_repo r
head -c 6000000 /dev/zero | tr '\0' 'a' > big.txt
blocked && ok "6MB file blocked" || no "6MB file blocked"; reset_repo r

echo "== Push layer =="
new_repo p; git init -q --bare "$T/bare.git"; git remote add origin "$T/bare.git"
mkdir -p data; cp "$RT/data/config.Prod.json" data/c.json
git add -f data >/dev/null 2>&1; git commit -qm leak --no-verify >/dev/null 2>&1
git push -q origin HEAD:main >/dev/null 2>&1; [ $? -ne 0 ] && ok "push blocked despite --no-verify" || no "push blocked despite --no-verify"

new_repo m; git init -q --bare "$T/bare2.git"; git remote add origin "$T/bare2.git"
git checkout -qb br; mkdir -p data; cp "$RT/data/config.Prod.json" data/c.json
git add -f data >/dev/null 2>&1; git commit -qm leak --no-verify >/dev/null 2>&1
git checkout -q master 2>/dev/null || git checkout -q main
echo m > m.txt; git add m.txt; git commit -qm m >/dev/null 2>&1
git merge br --no-edit >/dev/null 2>&1
git push -q origin HEAD:main >/dev/null 2>&1; [ $? -ne 0 ] && ok "push blocked when merge brings in data" || no "push blocked when merge brings in data"

echo "== Protected roots =="
mkdir -p "$RT/repo"; cd "$RT/repo"; git init -q .; git config user.email t@t; git config user.name t
cp "$GUARD_ROOT/template/hooks/"* .git/hooks/
echo x > a.txt; git add a.txt; git commit -qm x >/dev/null 2>&1
[ $? -ne 0 ] && ok "commit denied inside protected root" || no "commit denied inside protected root"

echo "== Binary content and overrides =="
new_repo b1
printf '\000\001sk-%s\000\377\n' "abcdefghijklmnopqrstuvwx" > blob.bin
blocked && ok "binary-embedded secret blocked" || no "binary-embedded secret blocked"; reset_repo b1
new_repo b2
printf 'const k="sk-%s";\n' "abcdefghijklmnopqrstuvwx" > k.js
GUARD_OVERRIDE=1 git add -A >/dev/null 2>&1
GUARD_OVERRIDE=1 git commit -qm x >/dev/null 2>&1
[ $? -eq 0 ] && ok "GUARD_OVERRIDE one-shot bypass" || no "GUARD_OVERRIDE one-shot bypass"; reset_repo b2
new_repo b3
mkdir -p fixtures; printf 'const k="sk-%s";\n' "abcdefghijklmnopqrstuvwx" > fixtures/k.js
echo '^/fixtures/' >> "$GUARD_DIR/allow-paths.txt"
passed && ok "allow-paths lets it pass" || no "allow-paths lets it pass"
sed -i '$d' "$GUARD_DIR/allow-paths.txt"; reset_repo b3

echo "== TMPDIR fallback =="
new_repo t1
mkdir -p data; echo '{}' > data/c.json
git add -f data >/dev/null 2>&1
env -u TMPDIR bash -c '. "$GUARD_ROOT/guard-lib.sh"; guard_pre_commit' >/dev/null 2>&1
[ $? -ne 0 ] && ok "still blocks without TMPDIR" || no "still blocks without TMPDIR"; reset_repo t1
rm -rf "$TMPDIR"/gg.* 2>/dev/null
bash -c '. "$GUARD_ROOT/guard-lib.sh"; g_tmp_init; g_tmpclean' >/dev/null 2>&1
[ "$(ls -d "$TMPDIR"/gg.* 2>/dev/null | wc -l)" -eq 0 ] && ok "no temp dirs left behind" || no "no temp dirs left behind"

echo "== Push layer binary =="
new_repo p2; git init -q --bare "$T/bare3.git"; git remote add origin "$T/bare3.git"
printf '\000sk-%s\000\n' "abcdefghijklmnopqrstuvwx" > blob.bin
git add -A >/dev/null 2>&1; git commit -qm leak --no-verify >/dev/null 2>&1
git push -q origin HEAD:master >/dev/null 2>&1
[ $? -ne 0 ] && ok "push layer blocks binary secret" || no "push layer blocks binary secret"

echo "== wsnap =="
WS="$T/ws"; mkdir -p "$WS/sub"; echo a > "$WS/a.txt"; echo b > "$WS/sub/b.txt"
run_wsnap(){ WSN_ROOT="$WS" WSN_STATE="$GUARD_DIR/wsnap" "$SRC/bin/wsnap" "$@" 2>&1; }
run_wsnap init >/dev/null
run_wsnap verify | grep -q "0 added / 0 modified / 0 deleted" && ok "wsnap baseline clean" || no "wsnap baseline clean"
echo c > "$WS/c.txt"
run_wsnap verify | grep -q "1 added" && ok "wsnap detects addition" || no "wsnap detects addition"
mkdir -p "$WS/data"; echo '{}' > "$WS/data/x.json"
run_wsnap verify >/dev/null 2>&1; [ $? -eq 3 ] && ok "wsnap returns 3 on suspicious path" || no "wsnap returns 3 on suspicious path"
run_wsnap verify --accept >/dev/null 2>&1
run_wsnap verify >/dev/null 2>&1; [ $? -eq 0 ] && ok "wsnap --accept works" || no "wsnap --accept works"

echo "== Notification layer =="
new_repo n1
mkdir -p data; echo '{}' > data/c.json
git add -f data >/dev/null 2>&1
GUARD_NOTIFY=1 git commit -qm x >/dev/null 2>&1
[ -s "$GUARD_DIR/last-block.txt" ] && ok "report written on block" || no "report written on block"
grep -q "^REPO=" "$GUARD_DIR/last-block.txt" 2>/dev/null \
  && grep -q "data/c.json" "$GUARD_DIR/last-block.txt" 2>/dev/null \
  && ok "report contains repo and hit files" || no "report contains repo and hit files"
# No report when notifications are off (GUARD_NOTIFY=0 takes the disabled branch; report still lives in g_notify)
rm -f "$GUARD_DIR/last-block.txt"
GUARD_NOTIFY=0 git commit -qm y >/dev/null 2>&1
[ ! -s "$GUARD_DIR/last-block.txt" ] && ok "GUARD_NOTIFY=0 writes no report" || no "GUARD_NOTIFY=0 writes no report"
touch "$GUARD_DIR/notify.off"
GUARD_NOTIFY=1 git commit -qm z >/dev/null 2>&1
[ ! -s "$GUARD_DIR/last-block.txt" ] && ok "notify.off disables notifications" || no "notify.off disables notifications"
rm -f "$GUARD_DIR/notify.off"; reset_repo n1

echo "== Notification button: Allow once =="
new_repo a1
mkdir -p data; echo '{}' > data/c.json
git add -f data >/dev/null 2>&1
git commit -qm x >/dev/null 2>&1
[ $? -ne 0 ] && ok "blocked before bypass" || no "blocked before bypass"
printf 'REPO=%s\nKIND=commit\nEXPIRE=%s\n' "$PWD" "$(( $(date +%s) + 600 ))" > "$GUARD_DIR/override-one-shot"
git commit -qm x >/dev/null 2>&1
[ $? -eq 0 ] && ok "token allows once" || no "token allows once"
[ ! -e "$GUARD_DIR/override-one-shot" ] && ok "token consumed after use" || no "token consumed after use"
mkdir -p data; echo y > data/y.json; git add -f data >/dev/null 2>&1
git commit -qm x >/dev/null 2>&1
[ $? -ne 0 ] && ok "blocks again after token is spent" || no "blocks again after token is spent"
reset_repo a1
new_repo a2
mkdir -p data; echo '{}' > data/c.json; git add -f data >/dev/null 2>&1
printf 'REPO=%s\nKIND=commit\nEXPIRE=%s\n' "$PWD" "$(( $(date +%s) - 10 ))" > "$GUARD_DIR/override-one-shot"
git commit -qm x >/dev/null 2>&1
[ $? -ne 0 ] && ok "expired token does not allow" || no "expired token does not allow"
[ ! -e "$GUARD_DIR/override-one-shot" ] && ok "expired token also consumed" || no "expired token also consumed"
reset_repo a2

echo "== Notification dismissal =="
new_repo d1
mkdir -p data; echo '{}' > data/c.json
git add -f data >/dev/null 2>&1
GUARD_NOTIFY=1 git commit -qm x >/dev/null 2>&1
[ -s "$GUARD_DIR/last-block.txt" ] && ok "report exists after block" || no "report exists after block"
reset_repo d1
GUARD_NOTIFY=1 git commit -qm ok >/dev/null 2>&1
[ ! -e "$GUARD_DIR/last-block.txt" ] && ok "stale report cleared after pass" || no "stale report cleared after pass"
reset_repo d1

echo
echo "passed $pass / failed $fail"
[ "$fail" -eq 0 ]
