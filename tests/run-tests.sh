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

head_ "11. 다른 셸에서 호출"
for s in bash zsh; do
  command -v "$s" >/dev/null 2>&1 || continue
  out=$("$s" -c "AW_HOME='$AW_HOME' '$AW' run -n from-$s -- echo 안녕 >/dev/null 2>&1; AW_HOME='$AW_HOME' '$AW' wait from-$s >/dev/null 2>&1; AW_HOME='$AW_HOME' '$AW' result from-$s" 2>&1)
  check "$s 에서 호출" 안녕 "$out"
done

printf '\n통과 %d / 실패 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
