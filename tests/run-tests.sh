#!/usr/bin/env bash
# aw 자체 검증
#
# 실제 홈이나 사용자의 워커 기록을 건드리지 않습니다.
# AW_HOME 을 임시 디렉터리로 잡고, 에이전트 없이 평범한 명령으로만 시험합니다.

set -u

SRC_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
AW="$SRC_DIR/aw"
PASS=0
FAIL=0

ok()    { PASS=$((PASS+1)); printf '  \033[32mOK\033[0m   %s\n' "$1"; }
ng()    { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else ng "$1 (기대: [$2] 실제: [$3])"; fi; }

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/aw-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT
export AW_HOME="$TMPROOT/awhome"

head_ "1. 문법 검사"
for s in sh bash zsh; do
  command -v "$s" >/dev/null 2>&1 || continue
  if "$s" -n "$AW" 2>/dev/null; then ok "$s -n aw"; else ng "$s -n aw"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S error "$AW" >/dev/null 2>&1 && ok "shellcheck (error 수준)" || ng "shellcheck 오류"
else
  echo "  (shellcheck 없음: 생략)"
fi

head_ "2. 기본 수명 주기"
"$AW" run -n basic -- sh -c 'echo 한줄; sleep 1; echo 두줄' >/dev/null 2>&1
state=$("$AW" list --json | sed -n 's/.*"name":"basic","state":"\([a-z]*\)".*/\1/p')
check "띄운 직후 running" running "$state"
"$AW" wait basic >/dev/null 2>&1
check "wait 후 종료 코드 0" 0 "$?"
check "결과 내용" "$(printf '한줄\n두줄')" "$("$AW" result basic)"
state=$("$AW" list --json | sed -n 's/.*"name":"basic","state":"\([a-z]*\)".*/\1/p')
check "끝난 뒤 done" done "$state"

head_ "3. 실패와 중단"
"$AW" run -n failing -- sh -c 'echo 나쁨 >&2; exit 7' >/dev/null 2>&1
"$AW" wait failing >/dev/null 2>&1
check "실패 워커는 0 이 아닌 코드로 wait 종료" 1 "$?"
check "종료 코드 기록" 7 "$(cat "$AW_HOME/workers/failing/exit")"
check "표준 오류 보존" 나쁨 "$("$AW" errs failing)"
state=$("$AW" list --json | sed -n 's/.*"name":"failing","state":"\([a-z]*\)".*/\1/p')
check "상태 failed" failed "$state"

"$AW" run -n longjob -- sleep 300 >/dev/null 2>&1
sleep 1
"$AW" stop longjob >/dev/null 2>&1
sleep 1
state=$("$AW" list --json | sed -n 's/.*"name":"longjob","state":"\([a-z]*\)".*/\1/p')
check "stop 후 상태 stopped" stopped "$state"
pid=$(cat "$AW_HOME/workers/longjob/pid" 2>/dev/null)
if kill -0 "$pid" 2>/dev/null; then ng "stop 했는데 프로세스가 살아 있음"; else ok "프로세스가 실제로 죽음"; fi

head_ "4. 표준 입력"
"$AW" run -n stdin-default -- cat >/dev/null 2>&1
"$AW" wait stdin-default --timeout 15 >/dev/null 2>&1
check "기본 표준 입력은 /dev/null (멈추지 않음)" "" "$("$AW" result stdin-default)"
printf '첫 줄\n둘째 줄\n' > "$TMPROOT/prompt.txt"
"$AW" run -n stdin-file -f "$TMPROOT/prompt.txt" -- cat >/dev/null 2>&1
"$AW" wait stdin-file >/dev/null 2>&1
check "--stdin-file 이 표준 입력으로 들어감" "$(printf '첫 줄\n둘째 줄')" "$("$AW" result stdin-file)"

head_ "5. 인자와 환경변수 보존"
"$AW" run -n quoting -- sh -c 'printf "%s\n" "따옴표 '"'"' 큰 \" 달러 \$HOME 역슬래시 \\"' >/dev/null 2>&1
"$AW" wait quoting >/dev/null 2>&1
check "특수문자가 그대로 전달됨" '따옴표 '"'"' 큰 " 달러 $HOME 역슬래시 \' "$("$AW" result quoting)"
"$AW" run -n envtest -e AW_TEST_VAR=값 -- sh -c 'echo "$AW_TEST_VAR"' >/dev/null 2>&1
"$AW" wait envtest >/dev/null 2>&1
check "--env 전달" 값 "$("$AW" result envtest)"

head_ "6. JSON 출력과 필드 추출"
json='{"is_error":false,"result":"여러 줄\n\"인용\" 포함","session_id":"abc-123"}'
"$AW" run -n jsonout -- printf '%s' "$json" >/dev/null 2>&1
"$AW" wait jsonout >/dev/null 2>&1
check "--field 로 문자열 필드 추출" "$(printf '여러 줄\n"인용" 포함')" "$("$AW" result jsonout --field result)"
check "--field session_id" abc-123 "$("$AW" result jsonout --field session_id)"
if "$AW" list --json | tail -1 | grep -q '^\]$'; then ok "list --json 이 올바르게 닫힘"; else ng "list --json 형식 오류"; fi

head_ "7. 이름 검증"
for bad in "../evil" "a b" ".hidden" ""; do
  if "$AW" run -n "$bad" -- true >/dev/null 2>&1; then ng "잘못된 이름을 받아들임: [$bad]"; else ok "잘못된 이름 거부: [$bad]"; fi
done
if "$AW" run -n basic -- true >/dev/null 2>&1; then ng "이름 중복을 허용함"; else ok "이름 중복 거부"; fi
if [ -d "$AW_HOME/workers/../evil" ]; then ng "경로 탈출로 디렉터리가 생김"; else ok "경로 탈출 없음"; fi

head_ "8. 셸에서 떼어내기"
sh -c "AW_HOME='$AW_HOME' '$AW' run -n detached -- sh -c 'sleep 3; echo 살아남음'" >/dev/null 2>&1
"$AW" wait detached --timeout 30 >/dev/null 2>&1
check "부모 셸이 끝나도 워커가 완주" 살아남음 "$("$AW" result detached)"

head_ "9. git worktree 격리"
REPO="$TMPROOT/repo"
mkdir -p "$REPO"
(cd "$REPO" && git init -q && git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init)
"$AW" run -n wt -d "$REPO" -w feat/aw-test -- sh -c 'git branch --show-current' >/dev/null 2>&1
"$AW" wait wt >/dev/null 2>&1
check "worktree 안에서 새 브랜치로 실행됨" feat/aw-test "$("$AW" result wt)"
if [ -d "$REPO/.aw-worktrees/wt" ]; then ok "worktree 디렉터리 생성"; else ng "worktree 없음"; fi
"$AW" rm wt >/dev/null 2>&1
if [ -d "$REPO/.aw-worktrees/wt" ]; then ng "rm 후에도 worktree 가 남음"; else ok "rm 이 worktree 까지 정리"; fi
if "$AW" run -n notgit -d "$TMPROOT" -w some/branch -- true >/dev/null 2>&1; then
  ng "git 저장소가 아닌데 worktree 를 만듦"
else
  ok "git 저장소가 아니면 worktree 거부"
fi

head_ "10. 정리"
"$AW" run -n tokeep -- sleep 60 >/dev/null 2>&1
sleep 1
"$AW" clean >/dev/null 2>&1
if [ -d "$AW_HOME/workers/tokeep" ]; then ok "clean 은 실행 중 워커를 남김"; else ng "clean 이 실행 중 워커를 지움"; fi
if [ -d "$AW_HOME/workers/basic" ]; then ng "clean 이 끝난 워커를 안 지움"; else ok "clean 이 끝난 워커를 지움"; fi
if "$AW" rm tokeep >/dev/null 2>&1; then ng "실행 중인데 rm 이 성공함"; else ok "실행 중 워커는 rm 거부"; fi
"$AW" clean --all >/dev/null 2>&1
if [ -d "$AW_HOME/workers/tokeep" ]; then ng "clean --all 이 안 지움"; else ok "clean --all 이 실행 중 워커까지 정리"; fi

head_ "11. 컨텍스트 한도 경고"
# 실제 에이전트 없이 같은 이름의 가짜 명령으로 시험합니다.
STUB="$TMPROOT/stub"
mkdir -p "$STUB"
for n in devin claude; do printf '#!/bin/sh\nexit 0\n' > "$STUB/$n"; chmod +x "$STUB/$n"; done
PATH="$STUB:$PATH"; export PATH

# 한글 1.5MB ≈ 74만 토큰 (devin 한도 262K 초과)
yes '가나다라마바사아자차카타파하 한국어 예시 문장입니다' | head -n 20000 > "$TMPROOT/big-ko.txt"
# 영어 224KB ≈ 5.6만 토큰 (한도 안쪽)
yes 'this is an english sample sentence for token estimation' | head -n 4000 > "$TMPROOT/small-en.txt"

out=$("$AW" run -n ctx-big -f "$TMPROOT/big-ko.txt" -- devin -p 2>&1)
case "$out" in *"컨텍스트 한도"*) ok "한도를 넘으면 경고" ;; *) ng "경고가 없음" ;; esac
est=$(sed -n 's/^input_tokens_est=//p' "$AW_HOME/workers/ctx-big/meta")
if [ "${est:-0}" -gt 262000 ]; then ok "추정 토큰 수를 meta 에 기록 ($est)"; else ng "추정값 이상: $est"; fi

out=$("$AW" run -n ctx-small -f "$TMPROOT/small-en.txt" -- devin -p 2>&1)
case "$out" in *"컨텍스트 한도"*) ng "한도 안쪽인데 경고함" ;; *) ok "한도 안쪽이면 조용함" ;; esac

out=$("$AW" run -n ctx-claude -f "$TMPROOT/big-ko.txt" -- claude -p 2>&1)
case "$out" in *"컨텍스트 한도"*) ng "claude(1M) 인데 경고함" ;; *) ok "에이전트별 한도를 구분함" ;; esac

out=$("$AW" run -n ctx-off -f "$TMPROOT/big-ko.txt" --max-input-tokens 0 -- devin -p 2>&1)
case "$out" in *"컨텍스트 한도"*) ng "--max-input-tokens 0 인데 경고함" ;; *) ok "--max-input-tokens 0 으로 끌 수 있음" ;; esac

AW_CONFIG="$TMPROOT/contexts"; export AW_CONFIG
printf 'claude 100\n' > "$AW_CONFIG"
out=$("$AW" run -n ctx-override -f "$TMPROOT/small-en.txt" -- claude -p 2>&1)
case "$out" in *"한도 100"*) ok "사용자 설정이 기본값을 덮어씀" ;; *) ng "설정 파일이 반영되지 않음" ;; esac
unset AW_CONFIG
case "$("$AW" contexts)" in *devin*262000*) ok "aw contexts 가 표를 보여줌" ;; *) ng "aw contexts 출력 이상" ;; esac
"$AW" clean --all >/dev/null 2>&1

head_ "12. 에이전트별 기본 옵션"
DSTUB="$TMPROOT/dstub"
mkdir -p "$DSTUB"
for n in agy claude myagent; do printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$DSTUB/$n"; chmod +x "$DSTUB/$n"; done
PATH="$DSTUB:$PATH"; export PATH

out=$("$AW" run -n def-agy -- agy -p=질문 2>&1)
case "$out" in *"기본 옵션이 붙었습니다"*) ok "기본 옵션을 붙였다고 알려 줌" ;; *) ng "알림 없음" ;; esac
"$AW" wait def-agy >/dev/null 2>&1
check "agy 에 권한 우회가 붙음" "$(printf -- '-p=질문\n--dangerously-skip-permissions')" "$("$AW" result def-agy)"

"$AW" run -n def-claude -- claude -p 질문 >/dev/null 2>&1
"$AW" wait def-claude >/dev/null 2>&1
check "값이 딸린 옵션도 온전히 붙음" "$(printf -- '-p\n질문\n--permission-mode\nbypassPermissions')" "$("$AW" result def-claude)"

"$AW" run -n def-user -- claude -p 질문 --permission-mode acceptEdits >/dev/null 2>&1
"$AW" wait def-user >/dev/null 2>&1
check "사용자 지정이 있으면 덧붙이지 않음" "$(printf -- '-p\n질문\n--permission-mode\nacceptEdits')" "$("$AW" result def-user)"

"$AW" run -n def-off --no-defaults -- agy -p=질문 >/dev/null 2>&1
"$AW" wait def-off >/dev/null 2>&1
check "--no-defaults 로 끌 수 있음" '-p=질문' "$("$AW" result def-off)"

AW_DEFAULTS="$TMPROOT/defaults"; export AW_DEFAULTS
printf 'myagent --yolo --quiet\n' > "$AW_DEFAULTS"
"$AW" run -n def-custom -- myagent 작업 >/dev/null 2>&1
"$AW" wait def-custom >/dev/null 2>&1
check "사용자가 새 에이전트를 추가할 수 있음" "$(printf '작업\n--yolo\n--quiet')" "$("$AW" result def-custom)"
unset AW_DEFAULTS
case "$("$AW" defaults)" in *dangerously-skip-permissions*) ok "aw defaults 가 표를 보여줌" ;; *) ng "aw defaults 출력 이상" ;; esac
"$AW" clean --all >/dev/null 2>&1

head_ "13. 도움말"
h=$("$AW" help)
for want in "aw run" "aw wait" "wait 종료 코드" "running / done" "aw help agents"; do
  case "$h" in *"$want"*) ok "개요에 '$want' 있음" ;; *) ng "개요에 '$want' 없음" ;; esac
done
lines=$(printf '%s\n' "$h" | wc -l)
if [ "$lines" -lt 60 ]; then ok "개요가 짧음 (${lines}줄)"; else ng "개요가 너무 김 (${lines}줄)"; fi
for topic in agents defaults files limits; do
  if "$AW" help "$topic" >/dev/null 2>&1; then ok "aw help $topic"; else ng "aw help $topic 실패"; fi
done
case "$("$AW" help agents)" in *codex*agy*|*agy*codex*) ok "agents 주제가 에이전트들을 다룸" ;; *) ng "agents 주제 내용 부족" ;; esac
if "$AW" help nosuchtopic >/dev/null 2>&1; then ng "없는 주제를 받아들임"; else ok "없는 주제는 0이 아닌 코드"; fi
if "$AW" run --help >/dev/null 2>&1; then ok "aw run --help"; else ng "aw run --help 실패"; fi
case "$("$AW" help files)" in *"$AW_HOME"*) ok "files 주제가 실제 경로를 보여줌" ;; *) ng "files 주제 경로 이상" ;; esac

head_ "14. 다른 셸에서 호출"
for s in bash zsh; do
  command -v "$s" >/dev/null 2>&1 || continue
  out=$("$s" -c "AW_HOME='$AW_HOME' '$AW' run -n from-$s -- echo 안녕 >/dev/null 2>&1; AW_HOME='$AW_HOME' '$AW' wait from-$s >/dev/null 2>&1; AW_HOME='$AW_HOME' '$AW' result from-$s" 2>&1)
  check "$s 에서 호출" 안녕 "$out"
done

printf '\n통과 %d / 실패 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
