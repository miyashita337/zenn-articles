#!/usr/bin/env bash
# tests/test_verify_sources.sh — scripts/verify-sources.sh の最小回帰テスト
# 実行: bash tests/test_verify_sources.sh   (exit 0 = 全 PASS)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/verify-sources.sh"
TMP="$(mktemp -d)"
trap 'rm -r -- "$TMP"' EXIT
fails=0
check() { # $1=name $2=expected $3=actual
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: expected [$2] got [$3]"; fails=$((fails + 1)); fi
}
# 無限ループ回帰（PR #18 レビュー指摘）を検出するため、引数解析系は 5 秒で打ち切る
with_timeout() { perl -e 'alarm shift; exec @ARGV' 5 "$@"; }

touch "$TMP/exists.txt"
cat > "$TMP/fixture.yaml" <<YAML
slug: fixture
sources:
  - id: S01
    claim: echo が 42 を返す
    kind: cmd
    cwd: "\$HOME"
    cmd: "echo 42"
    expect: "42"
  - id: S02
    claim: わざと不一致
    kind: cmd
    cwd: "$TMP"
    cmd: "echo 1"
    expect: "2"
  - id: S03
    claim: 手作業の出典
    kind: manual
    note: レシートで確認
  - id: S04
    claim: ファイル存在
    kind: file
    path: "$TMP/exists.txt"
YAML
cat > "$TMP/article.md" <<MD
本文 1
出典: なにか (S01)
出典: id なしの行
MD

# T1: FAIL を含む → exit 1、集計行、記事⇄yaml の不整合は FAIL 行
out="$(SOURCES_FILE="$TMP/fixture.yaml" ARTICLE_FILE="$TMP/article.md" bash "$SCRIPT" fixture 2>"$TMP/err")"; rc=$?
check "T1 exit code with FAIL" "1" "$rc"
check "T1 summary" "PASS 2 / FAIL 1 / SKIP 1" "$(echo "$out" | grep '^PASS ')"
check "T1 S02 row is FAIL" "1" "$(echo "$out" | grep -c '^| S02 .* FAIL |$')"
check "T1 FAIL yaml ids missing in article" "1" "$(grep -c '^FAIL: yaml にあるが記事の出典行に無い id: S02,S03,S04' "$TMP/err")"
check "T1 FAIL id-less 出典 line" "1" "$(grep -c '^FAIL: id の無い出典行: 1 行' "$TMP/err")"

# T2: --only で PASS だけ選ぶ → exit 0（--only=… 形式も同じ）
SOURCES_FILE="$TMP/fixture.yaml" ARTICLE_FILE="$TMP/article.md" bash "$SCRIPT" fixture --only S01,S04 >/dev/null 2>&1; rc=$?
check "T2 --only exit code" "0" "$rc"
SOURCES_FILE="$TMP/fixture.yaml" ARTICLE_FILE="$TMP/article.md" bash "$SCRIPT" fixture --only=S01,S04 >/dev/null 2>&1; rc=$?
check "T2 --only= exit code" "0" "$rc"

# T3: yaml 不在 → exit 2
SOURCES_FILE="$TMP/nope.yaml" bash "$SCRIPT" fixture >/dev/null 2>&1; rc=$?
check "T3 missing yaml exit code" "2" "$rc"

# T4: 引数なし → exit 2
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
check "T4 no slug exit code" "2" "$rc"

# T5: --only の値なし / 空 → exit 2（無限ループしない）
SOURCES_FILE="$TMP/fixture.yaml" with_timeout bash "$SCRIPT" fixture --only >/dev/null 2>&1; rc=$?
check "T5 --only without value exit code" "2" "$rc"
SOURCES_FILE="$TMP/fixture.yaml" with_timeout bash "$SCRIPT" fixture --only "" >/dev/null 2>&1; rc=$?
check "T5 --only empty value exit code" "2" "$rc"

# T6: --only に yaml に無い id → exit 2（PASS 0 で成功扱いしない）
SOURCES_FILE="$TMP/fixture.yaml" bash "$SCRIPT" fixture --only S99 2>"$TMP/err6" >/dev/null; rc=$?
check "T6 unknown --only id exit code" "2" "$rc"
check "T6 unknown id named" "1" "$(grep -c 'S99' "$TMP/err6")"
SOURCES_FILE="$TMP/fixture.yaml" bash "$SCRIPT" fixture --only S01,S99 >/dev/null 2>&1; rc=$?
check "T6 partially unknown --only exit code" "2" "$rc"

# T7: 記事⇄yaml の不整合だけで exit 1（コマンドは全 PASS）
cat > "$TMP/ok.yaml" <<YAML
slug: ok
sources:
  - id: S01
    claim: echo
    kind: cmd
    cwd: "\$HOME"
    cmd: "echo 1"
    expect: "1"
YAML
printf '出典なし本文\n' > "$TMP/nocite.md"
SOURCES_FILE="$TMP/ok.yaml" ARTICLE_FILE="$TMP/nocite.md" bash "$SCRIPT" ok >/dev/null 2>"$TMP/err7"; rc=$?
check "T7 article mismatch alone → exit 1" "1" "$rc"
check "T7 FAIL line" "1" "$(grep -c '^FAIL: yaml にあるが記事の出典行に無い id: S01' "$TMP/err7")"

# T8: citations_in_article: false → 突合は INFO のみで exit 0
{ printf 'citations_in_article: false\ncitations_note: 非公開 repo 由来のため本文非掲載\n'; cat "$TMP/ok.yaml"; } > "$TMP/nocite.yaml"
out="$(SOURCES_FILE="$TMP/nocite.yaml" ARTICLE_FILE="$TMP/nocite.md" bash "$SCRIPT" ok 2>"$TMP/err8")"; rc=$?
check "T8 citations_in_article false → exit 0" "0" "$rc"
check "T8 INFO line" "1" "$(echo "$out" | grep -c '^INFO: 本文の出典行は非掲載.*非公開 repo 由来')"
check "T8 no FAIL on stderr" "0" "$(grep -c '^FAIL' "$TMP/err8")"

# T9: cwd / path はシェルとして評価しない（コマンド置換・許可外の変数は FAIL、副作用なし）
cat > "$TMP/inject.yaml" <<YAML
slug: inject
sources:
  - id: S01
    claim: cwd にコマンド置換
    kind: cmd
    cwd: "\$(touch $TMP/pwned-cwd)"
    cmd: "echo 1"
    expect: "1"
  - id: S02
    claim: path にコマンド置換
    kind: file
    path: "\$(touch $TMP/pwned-path)/x"
  - id: S03
    claim: 許可外の環境変数
    kind: cmd
    cwd: "\$PATH"
    cmd: "echo 1"
    expect: "1"
  - id: S04
    claim: 許可された変数の波括弧形式
    kind: cmd
    cwd: "\${HOME}"
    cmd: "echo 1"
    expect: "1"
YAML
out="$(SOURCES_FILE="$TMP/inject.yaml" ARTICLE_FILE="$TMP/none.md" bash "$SCRIPT" inject 2>/dev/null)"; rc=$?
check "T9 injection exit code" "1" "$rc"
check "T9 no side effect (cwd)" "0" "$(ls "$TMP"/pwned-cwd 2>/dev/null | wc -l | tr -d ' ')"
check "T9 no side effect (path)" "0" "$(ls "$TMP"/pwned-path 2>/dev/null | wc -l | tr -d ' ')"
check "T9 S01 bad cwd" "1" "$(echo "$out" | grep -c '^| S01 .* (bad cwd) | FAIL |$')"
check "T9 S02 bad path" "1" "$(echo "$out" | grep -c '^| S02 .* (bad path) | FAIL |$')"
check "T9 S03 disallowed var" "1" "$(echo "$out" | grep -c '^| S03 .* (bad cwd) | FAIL |$')"
check "T9 S04 braces form PASS" "1" "$(echo "$out" | grep -c '^| S04 .* PASS |$')"

echo "---"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
