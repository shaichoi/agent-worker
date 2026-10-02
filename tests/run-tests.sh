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
has() { case "$2" in *"$3"*) ok "$1" ;; *) ng "$1 (출력: $(printf '%s' "$2" | head -12 | tr '\n' '|'))" ;; esac; }
hasnt() { case "$2" in *"$3"*) ng "$1" ;; *) ok "$1" ;; esac; }

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/aw-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT
export AW_HOME="$TMPROOT/awhome"
# 이 컴퓨터에 켜 둔 지시문과 기본 옵션이 시험용 명령에 붙지 않게 합니다 (그 시험은 따로 켬).
export AW_BRIEF="$TMPROOT/brief"
NO_DEFAULTS="$TMPROOT/no-defaults"   # 만들지 않는 파일: 기본 옵션이 꺼진 상태
export AW_DEFAULTS="$NO_DEFAULTS"
# aw pick 도 이 컴퓨터의 설정·키를 읽지 않게 합니다. 네트워크에는 나가지 않습니다 (curl 을 가짜로 바꿈).
export AW_PICK="$TMPROOT/pick" AW_PICK_KEYFILE="$TMPROOT/typesafe-key"
unset TYPESAFE_API_KEY TYPESAFE_BASE_URL TYPESAFE_DEFAULT_MODEL AW_PICK_MIN_CONFIDENCE AW_PICK_FALLBACK
# 모델 목록도 이 컴퓨터의 codex 설정(~/.codex)을 읽지 않게 합니다 (그 시험은 따로 가짜를 둠).
export CODEX_HOME="$TMPROOT/no-codex-home"
# claude 프로필(aw run --profile, aw gateway)도 이 컴퓨터의 ~/.claude-profiles 를 건드리지 않게 합니다.
export CLAUDE_PROFILE_ROOT="$TMPROOT/claude-profiles"

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

# stop 은 프로세스 그룹째 끊어야 합니다. 에이전트가 띄운 하위 프로세스(테스트
# 러너 등)가 고아로 남으면 워커는 사라졌는데 일은 계속 도는 상태가 됩니다.
# pgid 에 기대지 않고, 실제로 띄운 자식 pid 가 죽었는지로 확인합니다.
"$AW" run -n withkids -- sh -c 'sleep 313 & sleep 313 & wait' >/dev/null 2>&1
sleep 1
wpid=$(cat "$AW_HOME/workers/withkids/pid" 2>/dev/null || printf '')
kids=$(ps -eo pid=,ppid= | awk -v p="$wpid" '$2==p {print $1}')
nkids=$(printf '%s\n' "$kids" | grep -c '[0-9]')
if [ "$nkids" -ge 2 ]; then ok "하위 프로세스가 실제로 떠 있음 ($nkids)"; else ng "하위 프로세스가 안 떴음 ($nkids)"; fi
"$AW" stop withkids >/dev/null 2>&1
sleep 1
alive=0
for k in $kids; do kill -0 "$k" 2>/dev/null && alive=$((alive+1)); done
check "stop 이 하위 프로세스까지 정리 (고아 없음)" 0 "$alive"
state=$("$AW" list --json | sed -n 's/.*"name":"withkids","state":"\([a-z]*\)".*/\1/p')
check "하위 프로세스까지 죽여도 상태는 stopped" stopped "$state"
# 에이전트는 도구 명령을 새 세션으로 떼어 띄웁니다 (실측: claude, codex). 그룹째 끊어도
# 남으므로, 부모-자식으로 찾은 하위 프로세스도 끊어야 합니다.
if command -v setsid >/dev/null 2>&1; then
  "$AW" run -n newsess -- sh -c 'setsid sleep 317 & wait' >/dev/null 2>&1
  sleep 1
  sp=$(ps -eo pid=,args= | awk '$2 == "sleep" && $3 == "317" { print $1 }')
  if [ -n "$sp" ]; then ok "새 세션으로 뜬 하위 프로세스가 있음"; else ng "새 세션 하위 프로세스가 안 떴음"; fi
  "$AW" stop newsess >/dev/null 2>&1
  sleep 1
  alive=0; for k in $sp; do kill -0 "$k" 2>/dev/null && alive=1; done
  check "stop 이 새 세션으로 빠져나간 하위 프로세스도 끊음" 0 "$alive"
  for k in $sp; do kill -KILL "$k" 2>/dev/null; done
fi
if command -v setsid >/dev/null 2>&1; then
  gpid=$(cat "$AW_HOME/workers/withkids/pgid" 2>/dev/null || printf '')
  if [ -n "$gpid" ]; then ok "setsid 로 띄우면 pgid 를 남김"; else ng "pgid 파일이 없음"; fi

  # 명령이 스스로 새 그룹으로 빠져나가면 워커 그룹은 비어 버립니다.
  # 그룹만 보고 "끝났다" 판정하면 명령이 살아남은 채 stopped 로 기록됩니다.
  "$AW" run -n breakout -- setsid sh -c 'sleep 300' >/dev/null 2>&1
  sleep 1
  bpid=$(cat "$AW_HOME/workers/breakout/pid" 2>/dev/null || printf '')
  "$AW" stop breakout >/dev/null 2>&1
  sleep 1
  if [ -n "$bpid" ] && kill -0 "$bpid" 2>/dev/null; then
    ng "명령이 제 그룹으로 빠져나가면 stop 이 놓침"
    kill -KILL "$bpid" 2>/dev/null || true
  else
    ok "제 그룹으로 빠져나간 명령도 stop 이 정리"
  fi
fi

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
# 값에 공백이 있으면 예전엔 export 줄이 쪼개져 조용히 깨졌습니다.
"$AW" run -n env-space -e 'AW_TEST_VAR=여러 낱말 값' -- sh -c 'echo "$AW_TEST_VAR"' >/dev/null 2>&1
"$AW" wait env-space >/dev/null 2>&1
check "--env 값에 공백이 있어도 온전함" '여러 낱말 값' "$("$AW" result env-space)"
"$AW" run -n env-quote -e "AW_TEST_VAR=작은'따옴표 \"큰\" \$HOME" -- sh -c 'echo "$AW_TEST_VAR"' >/dev/null 2>&1
"$AW" wait env-quote >/dev/null 2>&1
check "--env 값의 따옴표와 \$ 가 그대로" "작은'따옴표 \"큰\" \$HOME" "$("$AW" result env-quote)"
"$AW" run -n env-many -e 'A=첫 값' -e 'B=둘째 값' -- sh -c 'echo "[$A][$B]"' >/dev/null 2>&1
"$AW" wait env-many >/dev/null 2>&1
check "--env 를 여러 번 줘도 각각 온전함" '[첫 값][둘째 값]' "$("$AW" result env-many)"
# 워커 안의 에이전트가 자기가 워커인지 알 수 있어야 스킬이 중첩을 막을 수 있습니다.
AW_WORKER='' "$AW" run -n env-worker -- sh -c 'echo "$AW_WORKER"' >/dev/null 2>&1
"$AW" wait env-worker >/dev/null 2>&1
check "워커 안에서 AW_WORKER 가 워커 이름" env-worker "$("$AW" result env-worker)"
# --profile 도 같은 자리에 쌓이므로 경로에 공백이 있으면 함께 깨졌습니다.
CLAUDE_PROFILE_ROOT='/tmp/공백 있는 경로' "$AW" run -n prof-space2 --profile work -- sh -c 'echo "$CLAUDE_CONFIG_DIR"' >/dev/null 2>&1
"$AW" wait prof-space2 >/dev/null 2>&1
check "--profile 경로에 공백이 있어도 온전함" '/tmp/공백 있는 경로/work' "$("$AW" result prof-space2)"

head_ "6. JSON 출력과 필드 추출"
json='{"is_error":false,"result":"여러 줄\n\"인용\" 포함","session_id":"abc-123"}'
"$AW" run -n jsonout -- printf '%s' "$json" >/dev/null 2>&1
"$AW" wait jsonout >/dev/null 2>&1
check "--field 로 문자열 필드 추출" "$(printf '여러 줄\n"인용" 포함')" "$("$AW" result jsonout --field result)"
check "--field session_id" abc-123 "$("$AW" result jsonout --field session_id)"
check "--field 는 따옴표 없는 값도 (false)" false "$("$AW" result jsonout --field is_error)"
"$AW" run -n jsonnum -- printf '%s' '{"num_turns":3,"cost":0.25,"x":null}' >/dev/null 2>&1
"$AW" wait jsonnum >/dev/null 2>&1
check "--field 숫자" 3 "$("$AW" result jsonnum --field num_turns)"
check "--field 소수" 0.25 "$("$AW" result jsonnum --field cost)"
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

# prune: 프로세스가 사라진 워커(lost)만 지움. 그룹에 남은 것이 있거나 worktree 에 변경이 있으면 남김
set_boot() { # <워커> <부팅 ID>  재부팅 전에 띄운 것처럼 meta 의 부팅 ID 를 바꿈
  sb_m="$AW_HOME/workers/$1/meta"
  { grep -v '^boot=' "$sb_m"; printf 'boot=%s\n' "$2"; } > "$sb_m.tmp" && mv "$sb_m.tmp" "$sb_m"
}
"$AW" run -n pr-done -- true >/dev/null 2>&1
"$AW" wait pr-done >/dev/null 2>&1
if [ -r /proc/sys/kernel/random/boot_id ]; then
  check "meta 에 부팅 ID 를 적음" "$(cat /proc/sys/kernel/random/boot_id)" "$(sed -n 's/^boot=//p' "$AW_HOME/workers/pr-done/meta")"
fi
check "lost 가 없으면 그렇게 알림" "프로세스가 사라진 워커가 없습니다." "$("$AW" prune 2>&1)"

# 재부팅 전에 띄운 워커: pid 가 살아 있어도(이제 남의 프로세스일 수 있음) lost
"$AW" run -n pr-boot -- sleep 30 >/dev/null 2>&1
pb_pid=$(cat "$AW_HOME/workers/pr-boot/pid"); pb_g=$(cat "$AW_HOME/workers/pr-boot/pgid" 2>/dev/null)
set_boot pr-boot not-this-boot
has "재부팅 전에 띄운 워커는 lost" "$("$AW" status pr-boot)" "상태     : lost"
has "재부팅 전 워커에는 stop 이 신호를 보내지 않음" "$("$AW" stop pr-boot 2>&1)" "재부팅 전에 띄운 워커라"
if kill -0 "$pb_pid" 2>/dev/null; then ok "stop 이 그 pid 의 프로세스를 건드리지 않음"; else ng "재부팅 전 워커의 pid 를 끊음"; fi
t0=$(date +%s); "$AW" wait pr-boot --timeout 20 >/dev/null 2>&1; rc=$?
check "재부팅 전 워커는 wait 가 기다리지 않고 1" 1 "$rc"
if [ $(( $(date +%s) - t0 )) -lt 5 ]; then ok "wait 가 바로 돌아옴"; else ng "wait 가 pid 를 기다림"; fi
has "prune 이 재부팅 전 워커를 지움" "$("$AW" prune 2>&1)" "지움: pr-boot (재부팅 전에 띄움"
if [ -d "$AW_HOME/workers/pr-boot" ]; then ng "pr-boot 기록이 남음"; else ok "pr-boot 기록이 지워짐"; fi
if [ -n "$pb_g" ]; then kill -9 "-$pb_g" 2>/dev/null; else kill -9 "$pb_pid" 2>/dev/null; fi

# 막 띄우는 중(pid 가 아직 없음)일 수 있으면 1분은 남김
mkdir -p "$AW_HOME/workers/pr-young"; printf 'name=pr-young\n' > "$AW_HOME/workers/pr-young/meta"
"$AW" prune >/dev/null 2>&1
if [ -d "$AW_HOME/workers/pr-young" ]; then ok "pid 가 없는 갓 만든 워커는 남김"; else ng "띄우는 중일 수 있는 워커를 지움"; fi
touch -t 202001010000 "$AW_HOME/workers/pr-young"
"$AW" prune >/dev/null 2>&1
if [ -d "$AW_HOME/workers/pr-young" ]; then ng "오래된 pid 없는 워커가 남음"; else ok "pid 없이 오래된 워커는 지움"; fi

if command -v setsid >/dev/null 2>&1; then
  # 그룹째 죽어 종료 코드를 남기지 못한 워커
  "$AW" run -n pr-lost -- sleep 30 >/dev/null 2>&1
  kill -9 "-$(cat "$AW_HOME/workers/pr-lost/pgid")" 2>/dev/null; sleep 1
  has "그룹째 죽은 워커는 lost" "$("$AW" status pr-lost)" "상태     : lost"
  has "prune --dry-run 은 지울 것을 보여 줌" "$("$AW" prune --dry-run 2>&1)" "지울 것: pr-lost (프로세스가 사라짐"
  if [ -d "$AW_HOME/workers/pr-lost" ]; then ok "prune --dry-run 은 지우지 않음"; else ng "prune --dry-run 이 지움"; fi
  "$AW" prune >/dev/null 2>&1
  if [ -d "$AW_HOME/workers/pr-lost" ]; then ng "prune 이 lost 워커를 남김"; else ok "prune 이 lost 워커를 지움"; fi
  if [ -d "$AW_HOME/workers/pr-done" ]; then ok "prune 은 끝난 워커(done)를 남김"; else ng "prune 이 끝난 워커를 지움"; fi

  # 명령은 죽었지만 그룹에 하위 프로세스가 남음 (에이전트가 띄운 서버 같은 것)
  "$AW" run -n pr-kids -- sh -c 'sleep 30 & sleep 30' >/dev/null 2>&1; sleep 1
  kill -9 "$(cat "$AW_HOME/workers/pr-kids/pgid")" "$(cat "$AW_HOME/workers/pr-kids/pid")" 2>/dev/null; sleep 1
  has "그룹에 살아 있는 것이 있으면 남기고 알림" "$("$AW" prune 2>&1)" "남김: pr-kids"
  if [ -d "$AW_HOME/workers/pr-kids" ]; then ok "그 워커 기록은 남음"; else ng "살아 있는 그룹의 워커를 지움"; fi
  "$AW" stop pr-kids >/dev/null 2>&1
  if kill -0 "-$(cat "$AW_HOME/workers/pr-kids/pgid")" 2>/dev/null; then ng "stop 뒤에도 그룹이 남음"; else ok "남은 그룹은 aw stop 으로 끊김"; fi
  "$AW" rm pr-kids >/dev/null 2>&1

  # worktree 에 커밋하지 않은 변경이 있으면 남김
  "$AW" run -n pr-wt -d "$REPO" -w feat/pr -- sh -c 'printf x > new.txt; sleep 30' >/dev/null 2>&1; sleep 1
  kill -9 "-$(cat "$AW_HOME/workers/pr-wt/pgid")" 2>/dev/null; sleep 1
  has "worktree 에 변경이 있으면 남기고 알림" "$("$AW" prune 2>&1)" "커밋하지 않은 변경이 있습니다"
  if [ -f "$REPO/.aw-worktrees/pr-wt/new.txt" ]; then ok "그 worktree 는 그대로 남음"; else ng "변경이 있는 worktree 를 지움"; fi
  "$AW" rm pr-wt >/dev/null 2>&1
fi
"$AW" clean >/dev/null 2>&1

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

head_ "12. 에이전트별 기본 옵션 (옵트인)"
DSTUB="$TMPROOT/dstub"
mkdir -p "$DSTUB"
for n in agy claude devin kiro-cli myagent; do printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$DSTUB/$n"; chmod +x "$DSTUB/$n"; done
PATH="$DSTUB:$PATH"; export PATH
AW_DEFAULTS="$TMPROOT/defaults"; export AW_DEFAULTS
rm -f "$AW_DEFAULTS"

# 설정 파일이 없으면 아무 옵션도 붙지 않아야 합니다 (조용한 권한 상승 방지)
"$AW" run -n def-none -- agy -p=질문 >/dev/null 2>&1
"$AW" wait def-none >/dev/null 2>&1
check "설정 파일이 없으면 덧붙이지 않음" '-p=질문' "$("$AW" result def-none)"
case "$("$AW" defaults)" in *"적용 중인 기본 옵션이 없습니다"*) ok "꺼져 있음을 알려 줌" ;; *) ng "꺼짐 안내 없음" ;; esac

# --init 로 켜기
"$AW" defaults --init >/dev/null 2>&1
if [ -f "$AW_DEFAULTS" ]; then ok "defaults --init 이 파일을 만듦"; else ng "파일이 안 생김"; fi
printf 'myagent --keep\n' >> "$AW_DEFAULTS"
"$AW" defaults --init >/dev/null 2>&1
if grep -q 'myagent --keep' "$AW_DEFAULTS"; then ok "--init 이 기존 파일을 덮어쓰지 않음"; else ng "기존 설정을 날림"; fi
"$AW" defaults --init --force >/dev/null 2>&1
if grep -q 'myagent --keep' "$AW_DEFAULTS"; then ng "--force 인데 안 덮어씀"; else ok "--init --force 는 덮어씀"; fi

out=$("$AW" run -n def-agy -- agy -p=질문 2>&1)
case "$out" in *"기본 옵션이 붙었습니다"*) ok "기본 옵션을 붙였다고 알려 줌" ;; *) ng "알림 없음" ;; esac
"$AW" wait def-agy >/dev/null 2>&1
check "agy 에 권한 우회와 기본 모델이 붙음 (줄마다 한 묶음)" \
  "$(printf -- '-p=질문\n--dangerously-skip-permissions\n--model\ngemini-3.8-flash\n--effort\nhigh')" "$("$AW" result def-agy)"
# 모델을 직접 고르면 모델 줄만 빠지고 권한 줄은 남습니다
"$AW" run -n def-agy-model -- agy -p=질문 --model gemini-3.1-pro-high >/dev/null 2>&1
"$AW" wait def-agy-model >/dev/null 2>&1
check "--model 을 직접 주면 모델 줄만 빠짐" \
  "$(printf -- '-p=질문\n--model\ngemini-3.1-pro-high\n--dangerously-skip-permissions')" "$("$AW" result def-agy-model)"
# 첫 옵션이 아니어도 겹치면 그 줄이 빠집니다. agy 는 gemini-3.8-flash-high 와 --effort low 가 부딪칩니다 (실측).
"$AW" run -n def-agy-effort -- agy -p=질문 --effort=low >/dev/null 2>&1
"$AW" wait def-agy-effort >/dev/null 2>&1
check "줄의 둘째 옵션(--effort=값)을 직접 줘도 그 줄이 빠짐" \
  "$(printf -- '-p=질문\n--effort=low\n--dangerously-skip-permissions')" "$("$AW" result def-agy-effort)"
# 프롬프트에 옵션 이름이 들어 있어도 옵션으로 치지 않습니다
"$AW" run -n def-agy-prompt -- agy '-p=--model 을 설명해줘' '--model 뒤에 공백' >/dev/null 2>&1
"$AW" wait def-agy-prompt >/dev/null 2>&1
check "프롬프트 속 옵션 이름은 옵션으로 치지 않음" \
  "$(printf -- '-p=--model 을 설명해줘\n--model 뒤에 공백\n--dangerously-skip-permissions\n--model\ngemini-3.8-flash\n--effort\nhigh')" \
  "$("$AW" result def-agy-prompt)"

# kiro-cli: 권한, 모델, 엔진이 따로 붙습니다. 기본 엔진(v2)은 --model 을 무시해서 v3 가 필요합니다 (실측).
"$AW" run -n def-kiro -- kiro-cli chat 질문 >/dev/null 2>&1
"$AW" wait def-kiro >/dev/null 2>&1
check "kiro-cli 에 권한, 모델, 엔진이 붙음" \
  "$(printf -- 'chat\n질문\n--trust-all-tools\n--model\nclaude-opus-5.5\n--agent-engine\nv3')" "$("$AW" result def-kiro)"
# --v2 는 --agent-engine 과 같이 주면 kiro-cli 가 오류를 냅니다 (실측). 같은 옵션으로 칩니다.
"$AW" run -n def-kiro-v2 -- kiro-cli chat --v2 -a 질문 >/dev/null 2>&1
"$AW" wait def-kiro-v2 >/dev/null 2>&1
check "kiro-cli: --v2 면 엔진 줄, -a 면 권한 줄이 빠짐" \
  "$(printf -- 'chat\n--v2\n-a\n질문\n--model\nclaude-opus-5.5')" "$("$AW" result def-kiro-v2)"
"$AW" run -n def-kiro-m -- kiro-cli chat --model=claude-sonnet-5 질문 >/dev/null 2>&1
"$AW" wait def-kiro-m >/dev/null 2>&1
check "kiro-cli: 모델을 직접 줘도 엔진 줄은 남음" \
  "$(printf -- 'chat\n--model=claude-sonnet-5\n질문\n--trust-all-tools\n--agent-engine\nv3')" "$("$AW" result def-kiro-m)"

"$AW" run -n def-claude -- claude -p 질문 >/dev/null 2>&1
"$AW" wait def-claude >/dev/null 2>&1
check "값이 딸린 옵션도 온전히 붙음 (claude 는 모델과 수준도)" "$(printf -- '-p\n질문\n--permission-mode\nbypassPermissions\n--model\nclaude-opus-5-5\n--effort\nxhigh')" "$("$AW" result def-claude)"
# claude 는 모델과 수준을 따로 둡니다. 모델만 바꾸면 수준은 남고, 수준만 바꾸면 모델이 남습니다.
"$AW" run -n def-claude-m -- claude -p 질문 --model sonnet >/dev/null 2>&1
"$AW" run -n def-claude-e -- claude -p 질문 --effort low >/dev/null 2>&1
"$AW" wait def-claude-m def-claude-e >/dev/null 2>&1
check "claude: 모델만 바꿔도 xhigh 는 남음" "$(printf -- '-p\n질문\n--model\nsonnet\n--permission-mode\nbypassPermissions\n--effort\nxhigh')" "$("$AW" result def-claude-m)"
check "claude: 수준만 바꿔도 Opus 는 남음" "$(printf -- '-p\n질문\n--effort\nlow\n--permission-mode\nbypassPermissions\n--model\nclaude-opus-5-5')" "$("$AW" result def-claude-e)"
# devin 은 승인 우회와 작업 공간 신뢰 검사 끄기를 한 줄에 같이 둡니다.
# -w 가 만드는 worktree 는 실행 시점에 생기는 경로라 미리 신뢰 등록을 할 수 없습니다.
"$AW" run -n def-devin -- devin -p 질문 >/dev/null 2>&1
"$AW" wait def-devin >/dev/null 2>&1
check "devin 에 신뢰 검사 끄기와 기본 모델(SWE-2)까지 붙음" "$(printf -- '-p\n질문\n--permission-mode\ndangerous\n--respect-workspace-trust\nfalse\n--model\nswe-2-max')" "$("$AW" result def-devin)"
# 줄 단위 판단이라, 그 줄의 첫 옵션을 직접 주면 줄 전체가 빠집니다 (문서화된 주의할 점).
"$AW" run -n def-devin-own -- devin -p 질문 --permission-mode smart >/dev/null 2>&1
"$AW" wait def-devin-own >/dev/null 2>&1
check "첫 옵션을 직접 주면 그 줄이 통째로 빠짐" "$(printf -- '-p\n질문\n--permission-mode\nsmart\n--model\nswe-2-max')" "$("$AW" result def-devin-own)"
"$AW" run -n def-devin-model -- devin -p 질문 --model claude-opus-5-5-high >/dev/null 2>&1
"$AW" wait def-devin-model >/dev/null 2>&1
check "devin 에 --model 을 직접 주면 SWE-2 는 안 붙음" \
  "$(printf -- '-p\n질문\n--model\nclaude-opus-5-5-high\n--permission-mode\ndangerous\n--respect-workspace-trust\nfalse')" "$("$AW" result def-devin-model)"

"$AW" run -n def-user -- claude -p 질문 --permission-mode acceptEdits >/dev/null 2>&1
"$AW" wait def-user >/dev/null 2>&1
check "사용자 지정이 있으면 덧붙이지 않음 (그 줄만)" "$(printf -- '-p\n질문\n--permission-mode\nacceptEdits\n--model\nclaude-opus-5-5\n--effort\nxhigh')" "$("$AW" result def-user)"

"$AW" run -n def-off --no-defaults -- agy -p=질문 >/dev/null 2>&1
"$AW" wait def-off >/dev/null 2>&1
check "--no-defaults 로 끌 수 있음" '-p=질문' "$("$AW" result def-off)"

printf 'myagent --yolo --quiet\n' >> "$AW_DEFAULTS"
"$AW" run -n def-custom -- myagent 작업 >/dev/null 2>&1
"$AW" wait def-custom >/dev/null 2>&1
check "사용자가 새 에이전트를 추가할 수 있음" "$(printf '작업\n--yolo\n--quiet')" "$("$AW" result def-custom)"
case "$("$AW" defaults)" in *dangerously-skip-permissions*) ok "aw defaults 가 적용 중인 표를 보여줌" ;; *) ng "aw defaults 출력 이상" ;; esac
case "$(cat "$AW_DEFAULTS")" in *"--respect-workspace-trust false"*) ok "권장값에 devin 신뢰 검사 끄기가 들어 있음" ;; *) ng "권장값에 신뢰 검사 옵션 없음" ;; esac
# 같은 옵션을 여러 줄에 적으면 앞 줄만 붙습니다 (앞 줄이 붙인 것도 이미 있는 것으로 봄)
printf 'myagent --dup 1\nmyagent --dup 2\n' >> "$AW_DEFAULTS"
"$AW" run -n def-dup -- myagent 작업 >/dev/null 2>&1
"$AW" wait def-dup >/dev/null 2>&1
check "같은 옵션이 여러 줄이면 앞 줄만" "$(printf '작업\n--yolo\n--quiet\n--dup\n1')" "$("$AW" result def-dup)"

# 읽기: aw defaults get
"$AW" defaults --init --force >/dev/null 2>&1
check "get <명령>: 묶음을 한 줄에 하나씩" \
  "$(printf -- '--dangerously-skip-permissions\n--model gemini-3.8-flash --effort high')" "$("$AW" defaults get agy)"
check "get <명령> <옵션>: 그 옵션이 든 묶음만" "--model claude-opus-5.5" "$("$AW" defaults get kiro-cli --model)"
check "get <명령> <별칭>: kiro-cli 의 --v3 는 --agent-engine 과 같은 것" "--agent-engine v3" "$("$AW" defaults get kiro-cli --v3)"
case "$("$AW" defaults get)" in "agy --dangerously-skip-permissions"*) ok "get: 주석 없이 적용될 줄 전부" ;; *) ng "get 출력 이상" ;; esac
check "get: 없는 명령은 빈 출력" "" "$("$AW" defaults get nobody)"

# 바꾸기: aw defaults set / unset
out=$("$AW" defaults set agy --model gemini-3.1-pro-high)
has "set: 바꾼 줄을 보여 줌" "$out" "- agy --model gemini-3.8-flash --effort high"
check "set: 옵션이 겹치는 줄을 제자리에서 바꿈" \
  "$(printf -- '--dangerously-skip-permissions\n--model gemini-3.1-pro-high')" "$("$AW" defaults get agy)"
if grep -q '^# 모델:' "$AW_DEFAULTS"; then ok "set: 주석은 그대로"; else ng "set 이 주석을 지움"; fi
"$AW" run -n def-set -- agy -p=질문 >/dev/null 2>&1
"$AW" wait def-set >/dev/null 2>&1
check "set 한 값이 다음 워커에 붙음" \
  "$(printf -- '-p=질문\n--dangerously-skip-permissions\n--model\ngemini-3.1-pro-high')" "$("$AW" result def-set)"
has "set: 같은 줄이면 그대로라고 알림" "$("$AW" defaults set agy --model gemini-3.1-pro-high)" "그대로"
hasnt "값만 바꾼 줄은 빠진 권장값으로 안 봄" "$("$AW" defaults | sed -n '/권장값 중/,$p')" "agy --model"
"$AW" defaults set kiro-cli --v2 >/dev/null 2>&1
check "set: 별칭(--v2)도 겹치는 줄(--agent-engine v3)을 바꿈" "--v2" "$("$AW" defaults get kiro-cli --agent-engine)"
hasnt "별칭(--v2)으로 바꾼 줄도 빠진 권장값으로 안 봄" "$("$AW" defaults | sed -n '/권장값 중/,$p')" "kiro-cli --agent-engine"
"$AW" defaults set myagent --new 1 >/dev/null 2>&1
check "set: 겹치는 줄이 없으면 끝에 넣음" "myagent --new 1" "$(tail -1 "$AW_DEFAULTS")"
printf 'myagent --x 1\nmyagent --y 2\n' >> "$AW_DEFAULTS"
"$AW" defaults set myagent --x 9 --y 9 >/dev/null 2>&1
check "set: 겹치는 줄이 여럿이면 하나로" "$(printf -- '--new 1\n--x 9 --y 9')" "$("$AW" defaults get myagent)"
cp "$AW_DEFAULTS" "$TMPROOT/defaults.before"
if "$AW" defaults set agy --model '공백 있는 값' >/dev/null 2>&1; then ng "set 이 공백 든 값을 받음"; else ok "set: 공백 든 값은 거절"; fi
if "$AW" defaults set agy model >/dev/null 2>&1; then ng "set 이 - 없는 옵션을 받음"; else ok "set: 첫 옵션이 - 로 시작하지 않으면 거절"; fi
if [ "$(cat "$AW_DEFAULTS")" = "$(cat "$TMPROOT/defaults.before")" ]; then ok "거절하면 파일을 안 건드림"; else ng "거절했는데 파일이 바뀜"; fi
"$AW" defaults unset agy --model >/dev/null 2>&1
check "unset <명령> <옵션>: 그 줄만 뺌" "--dangerously-skip-permissions" "$("$AW" defaults get agy)"
"$AW" defaults unset kiro-cli >/dev/null 2>&1
check "unset <명령>: 그 명령의 줄 전부" "" "$("$AW" defaults get kiro-cli)"
has "unset: 뺄 게 없으면 알림" "$("$AW" defaults unset kiro-cli)" "뺄 줄이 없습니다"
# 빠진 권장값을 알려 줌 (예전에 만든 파일에 새 권장값을 알리려고)
out=$("$AW" defaults)
has "aw defaults 가 빠진 권장값을 알려 줌" "$out" "권장값 중 이 파일에 없는 줄"
has "빠진 권장값: kiro-cli" "$out" "  kiro-cli --model claude-opus-5.5"
printf '# agy --model gemini-3.8-flash --effort high\n' >> "$AW_DEFAULTS"
hasnt "주석 처리한 권장 줄은 빠진 것으로 안 봄 (사용자가 끈 것)" "$("$AW" defaults | sed -n '/권장값 중/,$p')" "agy --model"
"$AW" defaults --init --force >/dev/null 2>&1
hasnt "권장값 그대로면 빠진 줄 안내가 없음" "$("$AW" defaults)" "권장값 중 이 파일에 없는 줄"
# 파일이 없을 때 set 은 권장값(권한 우회)을 켜지 않고 그 줄만 둡니다
rm -f "$AW_DEFAULTS"
"$AW" defaults set agy --model gemini-3.8-flash --effort low >/dev/null 2>&1
check "파일이 없으면 set 한 줄만 (권한 우회는 안 켬)" "agy --model gemini-3.8-flash --effort low" "$("$AW" defaults get)"
"$AW" clean --all >/dev/null 2>&1

# 설치 스크립트가 켜 주는지 / --no-defaults 로 건너뛰는지
IH="$TMPROOT/insthome"
rm -rf "$IH"; mkdir -p "$IH"
(cd "$SRC_DIR" && env -u AW_DEFAULTS -u AW_BRIEF HOME="$IH" XDG_CONFIG_HOME="$IH/.config" AW_PREFIX="$IH/bin" sh ./install.sh >/dev/null 2>&1)
if [ -f "$IH/.config/agent-worker/defaults" ]; then ok "install.sh 가 기본 옵션을 켜 줌"; else ng "install.sh 가 켜지 않음"; fi
rm -rf "$IH"; mkdir -p "$IH"
(cd "$SRC_DIR" && env -u AW_DEFAULTS -u AW_BRIEF HOME="$IH" XDG_CONFIG_HOME="$IH/.config" AW_PREFIX="$IH/bin" sh ./install.sh --no-defaults >/dev/null 2>&1)
if [ -f "$IH/.config/agent-worker/defaults" ]; then ng "--no-defaults 인데 켜 버림"; else ok "install.sh --no-defaults 는 켜지 않음"; fi
if [ -f "$IH/.config/agent-worker/brief" ]; then ok "install.sh 가 지시문을 켜 줌"; else ng "install.sh 가 지시문을 안 켬"; fi
rm -rf "$IH"; mkdir -p "$IH"
(cd "$SRC_DIR" && env -u AW_DEFAULTS -u AW_BRIEF HOME="$IH" XDG_CONFIG_HOME="$IH/.config" AW_PREFIX="$IH/bin" sh ./install.sh --no-brief >/dev/null 2>&1)
if [ -f "$IH/.config/agent-worker/brief" ]; then ng "--no-brief 인데 켜 버림"; else ok "install.sh --no-brief 는 지시문을 켜지 않음"; fi
AW_DEFAULTS="$NO_DEFAULTS"

head_ "13. 도움말"
h=$("$AW" help)
for want in "aw run" "aw wait" "wait 종료 코드" "running / done" "aw help agents"; do
  case "$h" in *"$want"*) ok "개요에 '$want' 있음" ;; *) ng "개요에 '$want' 없음" ;; esac
done
lines=$(printf '%s\n' "$h" | wc -l)
if [ "$lines" -lt 60 ]; then ok "개요가 짧음 (${lines}줄)"; else ng "개요가 너무 김 (${lines}줄)"; fi
for topic in agents defaults files limits peek brief pick models gateway; do
  if "$AW" help "$topic" >/dev/null 2>&1; then ok "aw help $topic"; else ng "aw help $topic 실패"; fi
  case "$h" in *"aw help $topic"*) ok "개요의 자세히에 $topic 이 있음" ;; *) ng "개요에 aw help $topic 안내 없음" ;; esac
done
hb=$("$AW" help brief)
for want in --no-brief AW_NO_BRIEF "brief --init" "예상 소요" claude codex agy devin --prompt-file "aw resume"; do
  case "$hb" in *"$want"*) ok "brief 주제에 '$want'" ;; *) ng "brief 주제에 '$want' 없음" ;; esac
done
hp=$("$AW" help peek)
for want in "aw watch" "--idle" AW_QUIET "생각 중" "조용함" "마지막 활동" "예상 소요" devin agy; do
  case "$hp" in *"$want"*) ok "peek 주제에 '$want'" ;; *) ng "peek 주제에 '$want' 없음" ;; esac
done
for sub in "brief" "peek" "watch" "wait" "skill" "setup" "resume" "run" "pick"; do
  if "$AW" $sub --help >/dev/null 2>&1; then ok "aw $sub --help"; else ng "aw $sub --help 실패"; fi
done
case "$("$AW" wait --help)" in *"3 "*"--idle"*) ok "aw wait --help 에 코드 3 과 --idle" ;; *) ng "aw wait --help 에 코드 3 설명 없음" ;; esac
case "$("$AW" peek --help)" in *"aw help peek"*) ok "aw peek --help 가 자세한 도움말을 가리킴" ;; *) ng "aw peek --help 에 안내 없음" ;; esac
case "$("$AW" help agents)" in *codex*agy*|*agy*codex*) ok "agents 주제가 에이전트들을 다룸" ;; *) ng "agents 주제 내용 부족" ;; esac
case "$("$AW" help agents)" in *"kiro-cli chat"*"--agent-engine v3"*) ok "agents 주제에 kiro-cli 와 엔진 주의할 점" ;; *) ng "agents 주제에 kiro-cli 없음" ;; esac
if "$AW" help nosuchtopic >/dev/null 2>&1; then ng "없는 주제를 받아들임"; else ok "없는 주제는 0이 아닌 코드"; fi
if "$AW" run --help >/dev/null 2>&1; then ok "aw run --help"; else ng "aw run --help 실패"; fi
case "$("$AW" help files)" in *"$AW_HOME"*) ok "files 주제가 실제 경로를 보여줌" ;; *) ng "files 주제 경로 이상" ;; esac
# 파일로 프롬프트 넣는 법은 에이전트마다 다릅니다. 넷 다 적혀 있어야 합니다.
lim=$("$AW" help limits)
for want in claude agy codex devin kiro-cli; do
  case "$lim" in *"$want"*) ok "limits 주제에 $want 파일 입력법 있음" ;; *) ng "limits 주제에 $want 없음" ;; esac
done
case "$lim" in *--prompt-file*) ok "devin 은 -f 가 아니라 --prompt-file 이라고 적힘" ;; *) ng "devin 의 --prompt-file 언급 없음" ;; esac

head_ "14. 다른 셸에서 호출"
for s in bash zsh; do
  command -v "$s" >/dev/null 2>&1 || continue
  out=$("$s" -c "AW_HOME='$AW_HOME' '$AW' run -n from-$s -- echo 안녕 >/dev/null 2>&1; AW_HOME='$AW_HOME' '$AW' wait from-$s >/dev/null 2>&1; AW_HOME='$AW_HOME' '$AW' result from-$s" 2>&1)
  check "$s 에서 호출" 안녕 "$out"
done

head_ "15. 세션 이어하기"
RSTUB="$TMPROOT/rstub"
mkdir -p "$RSTUB"
# JSON 을 내놓는 에이전트 셋 (필드 이름이 제각각인 것까지 흉내)
printf '#!/bin/sh\nprintf "{\\"session_id\\":\\"SID1\\",\\"result\\":\\"ok\\"}\\n"\nprintf "%%s\\n" "$@" >&2\n' > "$RSTUB/claude"
printf '#!/bin/sh\nprintf "{\\"conversation_id\\":\\"CID1\\",\\"response\\":\\"ok\\"}\\n"\nprintf "%%s\\n" "$@" >&2\n' > "$RSTUB/agy"
printf '#!/bin/sh\nprintf "{\\"thread_id\\":\\"TID1\\"}\\n"\nprintf "%%s\\n" "$@" >&2\n' > "$RSTUB/codex"
# devin 은 텍스트만 내놓습니다 (세션 ID 를 못 뽑는 쪽)
printf '#!/bin/sh\necho 텍스트만\nprintf "%%s\\n" "$@" >&2\n' > "$RSTUB/devin"
# kiro-cli stream-json 은 모든 사건에 sessionId(낙타 표기)를 싣습니다 (실측)
printf '#!/bin/sh\nprintf "{\\"type\\":\\"metadata\\",\\"data\\":{\\"sessionId\\":\\"KSID1\\"}}\\n"\nprintf "%%s\\n" "$@" >&2\n' > "$RSTUB/kiro-cli"
chmod +x "$RSTUB"/*
PATH="$RSTUB:$PATH"; export PATH
AW_DEFAULTS="$TMPROOT/rdefaults"; export AW_DEFAULTS
printf 'claude --permission-mode bypassPermissions\ncodex --sandbox workspace-write\n' > "$AW_DEFAULTS"
"$AW" clean --all >/dev/null 2>&1

# 세션 ID 를 찾아 meta 에 적는가
"$AW" run -n r-claude -- claude -p --output-format json 원래 >/dev/null 2>&1
"$AW" wait r-claude >/dev/null 2>&1
check "meta 에는 아직 없음 (찾기는 처음 볼 때)" "" "$(sed -n 's/^session=//p' "$AW_HOME/workers/r-claude/meta")"
case "$("$AW" status r-claude)" in *SID1*) ok "aw status 가 세션을 보여줌" ;; *) ng "status 에 세션 없음" ;; esac
check "한 번 찾으면 meta 에 적어 둠" SID1 "$(sed -n 's/^session=//p' "$AW_HOME/workers/r-claude/meta")"
case "$("$AW" list --json)" in *'"session":"SID1"'*) ok "list --json 에 session 필드" ;; *) ng "list --json 에 session 없음" ;; esac

# 에이전트별 argv
"$AW" resume r-claude -- 새프롬프트 >/dev/null 2>&1
"$AW" wait r-claude-r1 >/dev/null 2>&1
check "claude: --resume 을 붙이고 옛 프롬프트를 걷어냄" \
  "$(printf -- '--resume\nSID1\n-p\n--output-format\njson\n새프롬프트\n--permission-mode\nbypassPermissions')" \
  "$("$AW" errs r-claude-r1)"

"$AW" run -n r-agy -- agy --output-format json --model M -p=원래 >/dev/null 2>&1
"$AW" wait r-agy >/dev/null 2>&1
"$AW" resume r-agy -- 새프롬프트 >/dev/null 2>&1
"$AW" wait r-agy-r1 >/dev/null 2>&1
check "agy: --conversation 을 붙이고 -p= 를 갈아 끼움" \
  "$(printf -- '--conversation\nCID1\n--output-format\njson\n--model\nM\n-p=새프롬프트')" \
  "$("$AW" errs r-agy-r1)"

"$AW" run -n r-codex -- codex exec --json 원래 >/dev/null 2>&1
"$AW" wait r-codex >/dev/null 2>&1
"$AW" resume r-codex -- 새프롬프트 >/dev/null 2>&1
"$AW" wait r-codex-r1 >/dev/null 2>&1
check "codex: exec resume 으로 바꾸고 --sandbox 를 떼어냄" \
  "$(printf -- 'exec\nresume\nTID1\n--json\n새프롬프트')" \
  "$("$AW" errs r-codex-r1)"

# codex 의 stdin 표식 '-' 는 새 프롬프트와 같이 있으면 안 됩니다
printf '사양\n' > "$TMPROOT/rspec.md"
"$AW" run -n r-cxf -f "$TMPROOT/rspec.md" -- codex exec --json - >/dev/null 2>&1
"$AW" wait r-cxf >/dev/null 2>&1
"$AW" resume r-cxf -- 새프롬프트 >/dev/null 2>&1
"$AW" wait r-cxf-r1 >/dev/null 2>&1
check "codex: stdin 표식 - 를 걷어냄" \
  "$(printf -- 'exec\nresume\nTID1\n--json\n새프롬프트')" \
  "$("$AW" errs r-cxf-r1)"

# -f 로 돌린 워커는 인자에 프롬프트가 없으니 걷어낼 것도 없습니다
"$AW" run -n r-cf -f "$TMPROOT/rspec.md" -- claude -p --output-format json >/dev/null 2>&1
"$AW" wait r-cf >/dev/null 2>&1
"$AW" resume r-cf -- 새프롬프트 >/dev/null 2>&1
"$AW" wait r-cf-r1 >/dev/null 2>&1
check "-f 로 돌린 워커는 인자를 안 잃음" \
  "$(printf -- '--resume\nSID1\n-p\n--output-format\njson\n새프롬프트\n--permission-mode\nbypassPermissions')" \
  "$("$AW" errs r-cf-r1)"

# 이어하기를 또 이어해도 --resume 이 겹치지 않아야 합니다
"$AW" resume r-claude-r1 -- 세번째 >/dev/null 2>&1
"$AW" wait r-claude-r2 >/dev/null 2>&1
n=$("$AW" errs r-claude-r2 | grep -c -- '--resume')
check "이어하기를 또 이어해도 --resume 이 하나" 1 "$n"
check "이어하기의 이어하기도 새 프롬프트를 씀" \
  "$(printf -- '--resume\nSID1\n-p\n--output-format\njson\n세번째\n--permission-mode\nbypassPermissions')" \
  "$("$AW" errs r-claude-r2)"

# devin 은 세션 ID 가 없어 -c 로 갑니다
"$AW" run -n r-devin -- devin -p 원래 --model M >/dev/null 2>&1
"$AW" wait r-devin >/dev/null 2>&1
check "세션 ID 를 못 뽑으면 meta 에 안 적음" "" "$(sed -n 's/^session=//p' "$AW_HOME/workers/r-devin/meta")"
out=$("$AW" resume r-devin -- 이어서 2>&1)
case "$out" in *"-c"*) ok "devin 은 -c 로 간다고 알려 줌" ;; *) ng "devin -c 경고가 없음" ;; esac
"$AW" wait r-devin-r1 >/dev/null 2>&1
check "devin: -p 뒤에 프롬프트를 두고 -c 를 붙임" \
  "$(printf -- '-p\n이어서\n-c\n--model\nM')" \
  "$("$AW" errs r-devin-r1)"

# kiro-cli: chat 뒤에 --resume-id 를 붙이고, 맨 끝 프롬프트를 갈아 끼움
"$AW" run -n r-kiro -- kiro-cli chat --output-format stream-json 원래 >/dev/null 2>&1
"$AW" wait r-kiro >/dev/null 2>&1
check "kiro-cli: sessionId 를 세션으로 찾음" KSID1 "$("$AW" list --json | sed -n 's/.*"name":"r-kiro","state":"done","exit":"0",.*"session":"\([^"]*\)".*/\1/p')"
"$AW" resume r-kiro -- 새프롬프트 >/dev/null 2>&1
"$AW" wait r-kiro-r1 >/dev/null 2>&1
check "kiro-cli: chat --resume-id 를 붙이고 옛 프롬프트를 걷어냄" \
  "$(printf -- 'chat\n--resume-id\nKSID1\n--output-format\nstream-json\n새프롬프트')" \
  "$("$AW" errs r-kiro-r1)"
"$AW" resume r-kiro-r1 -- 세번째 >/dev/null 2>&1
"$AW" wait r-kiro-r2 >/dev/null 2>&1
check "kiro-cli: 이어하기를 또 이어해도 --resume-id 가 하나" 1 "$("$AW" errs r-kiro-r2 | grep -c -- '--resume-id')"
"$AW" run -n r-kiro-f -f "$TMPROOT/rspec.md" -- kiro-cli chat --output-format stream-json >/dev/null 2>&1
"$AW" wait r-kiro-f >/dev/null 2>&1
"$AW" resume r-kiro-f -- 새프롬프트 >/dev/null 2>&1
"$AW" wait r-kiro-f-r1 >/dev/null 2>&1
check "kiro-cli: -f 로 돌린 워커는 인자를 안 잃음" \
  "$(printf -- 'chat\n--resume-id\nKSID1\n--output-format\nstream-json\n새프롬프트')" \
  "$("$AW" errs r-kiro-f-r1)"
"$AW" run -n r-kiro-nochat -- kiro-cli --output-format stream-json 질문 >/dev/null 2>&1
"$AW" wait r-kiro-nochat >/dev/null 2>&1
if "$AW" resume r-kiro-nochat -- 이어서 >/dev/null 2>&1; then ng "chat 아닌 kiro-cli 를 이어함"; else ok "chat 으로 시작하지 않은 kiro-cli 는 거절"; fi

# 오류 경로
printf '#!/bin/sh\necho 텍스트만\n' > "$RSTUB/plain"; chmod +x "$RSTUB/plain"
"$AW" run -n r-plain -- plain >/dev/null 2>&1
"$AW" wait r-plain >/dev/null 2>&1
if "$AW" resume r-plain -- 이어서 >/dev/null 2>&1; then ng "모르는 에이전트를 이어함"; else ok "모르는 에이전트는 거절" ; fi
"$AW" run -n r-noexec -- codex --json 질문 >/dev/null 2>&1
"$AW" wait r-noexec >/dev/null 2>&1
if "$AW" resume r-noexec -- 이어서 >/dev/null 2>&1; then ng "exec 아닌 codex 를 이어함"; else ok "exec 로 시작하지 않은 codex 는 거절"; fi
"$AW" run -n r-run -- sleep 30 >/dev/null 2>&1
if "$AW" resume r-run -- 이어서 >/dev/null 2>&1; then ng "실행 중인 워커를 이어함"; else ok "실행 중인 워커는 거절"; fi
"$AW" stop r-run >/dev/null 2>&1
if "$AW" resume r-claude >/dev/null 2>&1; then ng "프롬프트 없이 이어함"; else ok "새 프롬프트가 없으면 거절"; fi
if "$AW" resume --help >/dev/null 2>&1; then ok "aw resume --help"; else ng "aw resume --help 실패"; fi
"$AW" clean --all >/dev/null 2>&1
AW_DEFAULTS="$NO_DEFAULTS"

head_ "16. 에이전트 스킬 (aw skill)"
SK="$SRC_DIR/skills/agent-worker/SKILL.md"
check "저장소의 SKILL.md 가 aw skill show 와 같음 (다르면: ./aw skill show > skills/agent-worker/SKILL.md)" \
  "$("$AW" skill show)" "$(cat "$SK")"
# agentskills.io 규격: name 은 폴더 이름과 같고, description 은 1~1024 자
fm=$(awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on' "$SK")
check "SKILL.md name 이 폴더 이름과 같음" agent-worker "$(printf '%s\n' "$fm" | sed -n 's/^name: //p')"
desc=$(printf '%s\n' "$fm" | sed -n 's/^description: //p')
# 글자 수는 로캘과 무관하게 셉니다: UTF-8 이어지는 바이트(0x80~0xBF)를 빼고 셈
dlen=$(printf '%s' "$desc" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')
if [ "$dlen" -ge 1 ] && [ "$dlen" -le 1024 ]; then ok "description 길이 $dlen 자 (1~1024)"; else ng "description 길이 $dlen 자"; fi
check "스킬의 version 이 aw 와 같음" "$(sed -n 's/^AW_VERSION=//p' "$AW")" \
  "$(printf '%s\n' "$fm" | sed -n 's/^  version: "\(.*\)"$/\1/p')"
if [ "$(wc -l < "$SK")" -lt 500 ]; then ok "SKILL.md 가 500 줄 미만"; else ng "SKILL.md 가 너무 김"; fi
# 스킬이 넘겨주는 도움말 주제가 실제로 있어야 합니다
for topic in $(grep -o '`aw help [a-z]*`' "$SK" | sed 's/`aw help \(.*\)`/\1/' | sort -u); do
  if "$AW" help "$topic" >/dev/null 2>&1; then ok "스킬이 가리키는 aw help $topic 이 있음"; else ng "스킬이 가리키는 aw help $topic 이 없음"; fi
done

# 에이전트가 있는지는 CLI(PATH) 나 설정 폴더로 봅니다. 실제 PATH 의 에이전트가 끼지 않게
# 가짜 bin 과 최소 PATH 로 돌립니다.
IH="$TMPROOT/skillhome"
fresh() { rm -rf "$IH"; mkdir -p "$IH/fakebin"; }
fake() { for f in "$@"; do printf '#!/bin/sh\n' > "$IH/fakebin/$f"; chmod +x "$IH/fakebin/$f"; done; }
awh() { env HOME="$IH" PATH="$IH/fakebin:/usr/bin:/bin" "$AW" "$@"; }
state_of_agent() { awh skill | awk -v a="$1" '$1 == a { print $3 ($4 == "버전" || $4 == "것" ? " " $4 : "") }'; }

fresh; mkdir -p "$IH/.claude"; fake codex
awh skill install >/dev/null 2>&1
check "설치된 claude(설정 폴더)에 넣음" "$("$AW" skill show)" "$(cat "$IH/.claude/skills/agent-worker/SKILL.md" 2>/dev/null)"
if [ -f "$IH/.agents/skills/agent-worker/SKILL.md" ]; then ok "설치된 codex(CLI)에는 ~/.agents 에 넣음"; else ng "~/.agents 에 없음"; fi
if [ -e "$IH/.gemini" ] || [ -e "$IH/.hermes" ]; then ng "없는 에이전트 폴더를 만들어 버림"; else ok "없는 에이전트(agy, hermes)는 건드리지 않음"; fi
if [ -e "$IH/.codex/skills/agent-worker" ]; then ng "~/.codex/skills 에도 넣어 Codex 에 두 번 보임"; else ok "~/.codex/skills 에는 넣지 않음 (중복 방지)"; fi
check "상태표: claude 최신" 최신 "$(state_of_agent claude)"
check "상태표: agy 없음" 없음 "$(state_of_agent agy)"
check "권한이 644" 644 "$(stat -c %a "$IH/.claude/skills/agent-worker/SKILL.md" 2>/dev/null || stat -f %Lp "$IH/.claude/skills/agent-worker/SKILL.md")"

fresh; fake codex devin
n=$(awh skill install 2>&1 | grep -c 'agents/skills')
check "codex 와 devin 이 같은 폴더를 쓰면 한 번만 넣음" 1 "$n"
awh skill install agy >/dev/null 2>&1
if [ -f "$IH/.gemini/config/skills/agent-worker/SKILL.md" ]; then ok "이름으로 고르면 없는 에이전트(agy)에도 넣음"; else ng "aw skill install agy 가 안 넣음"; fi
if awh skill install nobody >/dev/null 2>&1; then ng "모르는 에이전트를 받아들임"; else ok "모르는 에이전트는 거절"; fi

printf '추가된 줄\n' >> "$IH/.agents/skills/agent-worker/SKILL.md"
check "고쳐진 우리 스킬은 옛 버전" "옛 버전" "$(state_of_agent codex)"
awh skill install >/dev/null 2>&1
check "다시 넣으면 최신으로" 최신 "$(state_of_agent codex)"

fresh; fake codex
awh skill install --dry-run >/dev/null 2>&1
if [ -e "$IH/.agents" ]; then ng "--dry-run 인데 넣어 버림"; else ok "aw skill install --dry-run 은 쓰지 않음"; fi
fresh
out=$(awh skill install 2>&1)
case "$out" in *"찾은 에이전트가 없습니다"*) ok "에이전트가 없으면 알리고 아무것도 안 함" ;; *) ng "에이전트가 없는데: $out" ;; esac

# 같은 이름의 남의 스킬은 덮어쓰지도, 빼지도 않음
fresh; fake codex; mkdir -p "$IH/.claude/skills/agent-worker"
printf -- '---\nname: agent-worker\ndescription: 남의 것\n---\n' > "$IH/.claude/skills/agent-worker/SKILL.md"
awh skill install >/dev/null 2>&1
check "남의 스킬은 덮어쓰지 않음" "description: 남의 것" "$(sed -n 3p "$IH/.claude/skills/agent-worker/SKILL.md")"
check "상태표: 남의 것" "남의 것" "$(state_of_agent claude)"
mkdir -p "$IH/.agents/skills/agent-worker/references"; : > "$IH/.agents/skills/agent-worker/references/mine.md"
awh skill remove codex >/dev/null 2>&1
if [ -e "$IH/.agents/skills/agent-worker/SKILL.md" ]; then ng "aw skill remove codex 가 안 뺌"; else ok "aw skill remove 가 우리 스킬을 뺌"; fi
if [ -f "$IH/.agents/skills/agent-worker/references/mine.md" ]; then ok "사용자가 둔 다른 파일은 남김"; else ng "사용자 파일까지 지움"; fi
awh skill remove >/dev/null 2>&1
if [ -f "$IH/.claude/skills/agent-worker/SKILL.md" ]; then ok "aw skill remove 는 남의 스킬을 남김"; else ng "남의 스킬을 지움"; fi

# aw skill update: 이미 넣은 것만 새 버전으로, 새로 넣지는 않음
fresh; mkdir -p "$IH/.claude"; fake agy
awh skill install claude >/dev/null 2>&1
printf '추가된 줄\n' >> "$IH/.claude/skills/agent-worker/SKILL.md"
awh skill update >/dev/null 2>&1
check "update 가 옛 버전을 최신으로" 최신 "$(state_of_agent claude)"
check "update 는 없는 곳에 새로 넣지 않음" 없음 "$(state_of_agent agy)"
if awh skill install --ask < /dev/null >/dev/null 2>&1; then ng "터미널이 아닌데 --ask 가 통과"; else ok "--ask 는 터미널이 아니면 거절"; fi

# install.sh: 스킬은 묻고 넣음. 터미널이 없으면 새로 넣지 않고, 이미 넣은 것만 갱신
inst() { # [install.sh 옵션...]
  (cd "$SRC_DIR" && env -u AW_DEFAULTS -u AW_BRIEF HOME="$IH" XDG_CONFIG_HOME="$IH/.config" AW_PREFIX="$IH/bin" \
     PATH="$IH/fakebin:/usr/bin:/bin" sh ./install.sh "$@" >/dev/null 2>&1)
}
fresh; mkdir -p "$IH/.claude"; fake agy
inst
if [ -e "$IH/.claude/skills" ] || [ -e "$IH/.gemini" ]; then ng "터미널이 아닌데 묻지 않고 스킬을 넣음"; else ok "install.sh 는 터미널이 아니면 스킬을 새로 넣지 않음"; fi
if [ -x "$IH/bin/aw" ]; then ok "스킬을 안 넣어도 aw 는 설치됨"; else ng "aw 가 설치되지 않음"; fi
inst --skill
if [ -f "$IH/.claude/skills/agent-worker/SKILL.md" ] && [ -f "$IH/.gemini/config/skills/agent-worker/SKILL.md" ]; then
  ok "install.sh --skill 은 있는 에이전트마다 넣음"
else ng "install.sh --skill 이 빠뜨림"; fi
fresh; mkdir -p "$IH/.claude"; fake agy
inst --skill=agy
if [ -f "$IH/.gemini/config/skills/agent-worker/SKILL.md" ] && [ ! -e "$IH/.claude/skills" ]; then
  ok "install.sh --skill=agy 는 agy 에만 넣음"
else ng "install.sh --skill=agy 가 고른 대로 안 넣음"; fi
printf '추가된 줄\n' >> "$IH/.gemini/config/skills/agent-worker/SKILL.md"
inst
check "다시 설치하면 이미 넣은 스킬은 묻지 않고 새 버전으로" 최신 "$(state_of_agent agy)"
if [ -e "$IH/.claude/skills" ]; then ng "다시 설치하며 안 고른 claude 에 넣음"; else ok "다시 설치해도 안 고른 곳엔 넣지 않음"; fi
fresh; mkdir -p "$IH/.claude/skills/agent-worker"
awh skill install claude >/dev/null 2>&1; printf '추가된 줄\n' >> "$IH/.claude/skills/agent-worker/SKILL.md"
inst --no-skill
check "install.sh --no-skill 은 옛 버전도 건드리지 않음" "옛 버전" "$(state_of_agent claude)"
fresh; mkdir -p "$IH/.claude"
inst --dry-run
if [ -e "$IH/.claude/skills" ] || [ -e "$IH/bin/aw" ] || [ -e "$IH/.local/share/agent-worker" ]; then
  ng "install.sh --dry-run 이 무언가를 만듦"
else ok "install.sh --dry-run 은 아무것도 만들지 않음"; fi
fresh; mkdir -p "$IH/.claude" "$IH/.gemini/config/skills/agent-worker"; fake codex
printf -- '---\nname: agent-worker\ndescription: 남의 것\n---\n' > "$IH/.gemini/config/skills/agent-worker/SKILL.md"
inst --skill
# 제거는 이 시험의 설정 파일(AW_DEFAULTS 등)을 지우지 않게 AW_* 를 비우고 시험용 홈 아래로만 돌립니다.
uaw() { env -u AW_DEFAULTS -u AW_BRIEF -u AW_PICK -u AW_PICK_KEYFILE -u AW_CONFIG HOME="$IH" XDG_CONFIG_HOME="$IH/.config" \
          AW_HOME="$IH/awhome" AW_PREFIX="$IH/bin" PATH="$IH/fakebin:/usr/bin:/bin" "$@"; }
UREPO="$IH/repo"; mkdir -p "$UREPO"
(cd "$UREPO" && git init -q && git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init)
uaw "$IH/bin/aw" run -n un-wt -d "$UREPO" -w feat/un -- true >/dev/null 2>&1
uaw "$IH/bin/aw" run -n un-long -- sleep 60 >/dev/null 2>&1
uaw "$IH/bin/aw" wait un-wt >/dev/null 2>&1
un_pid=$(cat "$IH/awhome/workers/un-long/pid" 2>/dev/null)
un_left() { [ -e "$IH/bin/aw" ] || [ -e "$IH/awhome" ] || [ -e "$IH/.config/agent-worker" ] \
              || [ -e "$IH/.claude/skills/agent-worker" ] || [ -e "$IH/.agents/skills/agent-worker" ]; }

out=$(uaw "$IH/bin/aw" uninstall --dry-run 2>&1)
has "uninstall --dry-run: 지울 것을 보여 줌" "$out" "~/.config/agent-worker/defaults"
has "uninstall --dry-run: 실행 중인 워커를 멈춘다고 알림" "$out" "멈출 워커: un-long"
has "uninstall --dry-run: worktree 와 남는 브랜치를 알림" "$out" "브랜치 feat/un 는 남고"
has "uninstall --dry-run: 남의 스킬은 남긴다고 알림" "$out" "남김: ~/.gemini/config/skills/agent-worker"
if [ -x "$IH/bin/aw" ] && [ -d "$IH/awhome/workers/un-wt" ] && [ -f "$IH/.claude/skills/agent-worker/SKILL.md" ]; then
  ok "uninstall --dry-run 은 아무것도 지우지 않음"
else ng "uninstall --dry-run 이 무언가를 지움"; fi

if uaw "$IH/bin/aw" uninstall < /dev/null >/dev/null 2>&1; then ng "터미널이 아닌데 --yes 없이 성공"; else ok "uninstall: 터미널이 아니고 --yes 가 없으면 코드 1"; fi
if [ -x "$IH/bin/aw" ] && [ -d "$IH/awhome" ]; then ok "uninstall: --yes 없이는 지우지 않음"; else ng "uninstall: 확인 없이 지움"; fi

if command -v script >/dev/null 2>&1 && script -qec true /dev/null >/dev/null 2>&1; then
  un_tty() { printf '%s\n' "$1" | script -qec "env -u AW_DEFAULTS -u AW_BRIEF -u AW_PICK -u AW_PICK_KEYFILE -u AW_CONFIG HOME='$IH' XDG_CONFIG_HOME='$IH/.config' AW_HOME='$IH/awhome' AW_PREFIX='$IH/bin' PATH='$IH/fakebin:/usr/bin:/bin' sh '$IH/bin/aw' uninstall" /dev/null 2>&1; }
  out=$(un_tty n)
  has "uninstall: 터미널이면 한 번 물음" "$out" "모두 지울까요? [y/N]"
  if [ -x "$IH/bin/aw" ] && [ -d "$IH/awhome" ]; then ok "uninstall: n 이면 지우지 않음"; else ng "uninstall: n 인데 지움"; fi
fi

uaw "$IH/bin/aw" uninstall --yes >/dev/null 2>&1
if un_left; then ng "uninstall --yes 뒤에 남은 것이 있음"; else ok "uninstall --yes: 실행 파일·기록·설정·우리 스킬을 지움"; fi
if [ -f "$IH/.gemini/config/skills/agent-worker/SKILL.md" ]; then ok "uninstall 은 남의 스킬을 남김"; else ng "uninstall 이 남의 스킬을 지움"; fi
if [ -e "$UREPO/.aw-worktrees" ]; then ng "worktree(.aw-worktrees)가 남음"; else ok "uninstall 이 worktree 와 빈 .aw-worktrees 를 지움"; fi
check "uninstall 뒤에도 worktree 의 브랜치는 남음" feat/un "$(git -C "$UREPO" branch --list feat/un --format='%(refname:short)')"
if [ -n "$un_pid" ] && kill -0 "$un_pid" 2>/dev/null; then ng "실행 중이던 워커가 남음"; kill "$un_pid" 2>/dev/null; else ok "uninstall 이 실행 중인 워커를 멈춤"; fi

# 터미널에서 y 로 답하면 지움
if command -v script >/dev/null 2>&1 && script -qec true /dev/null >/dev/null 2>&1; then
  inst --no-skill
  un_tty y >/dev/null
  if [ -e "$IH/bin/aw" ]; then ng "uninstall: y 인데 안 지움"; else ok "uninstall: y 로 답하면 지움"; fi
fi

# 저장소에서 돌리면(uninstall.sh, ./aw uninstall) 저장소의 aw 는 남기고 설치한 aw 를 지움
inst --skill
uaw sh "$SRC_DIR/uninstall.sh" --yes >/dev/null 2>&1
if un_left; then ng "uninstall.sh --yes 뒤에 남은 것이 있음"; else ok "uninstall.sh 가 aw uninstall 로 모두 지움"; fi
if [ -f "$AW" ] && grep -q '^AW_VERSION=' "$AW"; then ok "저장소의 aw 는 남김"; else ng "저장소의 aw 를 지움"; fi
# 지운 뒤 다시 돌려도(이미 없음) 아무것도 만들지 않고 끝남
out=$(uaw sh "$AW" uninstall --dry-run 2>&1)
has "지울 것이 없으면 그렇게 알림" "$out" "지울 것이 없습니다"
if [ -e "$IH/awhome" ]; then ng "uninstall 이 기록 폴더를 새로 만듦"; else ok "uninstall 은 기록 폴더를 만들지 않음"; fi
# 설치 위치의 aw 가 aw 가 아니면(같은 이름의 남의 파일) 지우지 않음
mkdir -p "$IH/bin"; printf '#!/bin/sh\necho mine\n' > "$IH/bin/aw"
uaw sh "$AW" uninstall --yes >/dev/null 2>&1
check "설치 위치의 남의 aw 는 지우지 않음" mine "$(sh "$IH/bin/aw")"

# 스킬을 못 넣어도(쓰기 권한 없음) aw 설치는 끝까지 가야 합니다. root 는 권한을 무시해 건너뜁니다.
if [ "$(id -u)" -ne 0 ]; then
  fresh; mkdir -p "$IH/.claude"; chmod 555 "$IH/.claude"
  inst --skill; rc=$?
  chmod 755 "$IH/.claude"
  if [ "$rc" -eq 0 ] && [ -x "$IH/bin/aw" ]; then ok "스킬을 못 넣어도 aw 설치는 끝까지 감"; else ng "스킬 실패가 설치를 깨뜨림 (코드 $rc)"; fi
fi

# curl ... | sh 경로: 옆에 aw 가 없으면 받아오고, 스킬은 그 aw 안에 들어 있음 (file:// 로 흉내)
if command -v curl >/dev/null 2>&1; then
  pipe_inst() { # [install.sh 옵션...]
    (cd "$IH/empty" && env -u AW_DEFAULTS -u AW_BRIEF HOME="$IH" XDG_CONFIG_HOME="$IH/.config" AW_PREFIX="$IH/bin" \
       PATH="$IH/fakebin:/usr/bin:/bin" AW_RAW_URL="file://$AW" sh -s -- "$@" < "$SRC_DIR/install.sh" >/dev/null 2>&1)
  }
  fresh; mkdir -p "$IH/empty" "$IH/.claude"
  pipe_inst
  if [ -x "$IH/bin/aw" ] && [ ! -e "$IH/.claude/skills" ]; then ok "파이프 설치는 aw 만 넣고 스킬은 묻지 않고 넣지 않음"; else ng "파이프 설치 결과가 이상함"; fi
  pipe_inst --skill
  if [ -f "$IH/.claude/skills/agent-worker/SKILL.md" ]; then ok "파이프 설치도 --skill 이면 스킬을 넣음"; else ng "파이프 설치 --skill 이 안 넣음"; fi
  if command -v script >/dev/null 2>&1 && script -qec true /dev/null >/dev/null 2>&1; then
    # 파이프로 받은 스크립트도 터미널(/dev/tty)로 물어봄: claude 는 y, agy 는 그냥 Enter (기본 아니오)
    fresh; mkdir -p "$IH/empty" "$IH/.claude"; fake agy
    printf 'y\n\n' | script -qec "cd '$IH/empty' && env -u AW_DEFAULTS -u AW_BRIEF HOME='$IH' XDG_CONFIG_HOME='$IH/.config' AW_PREFIX='$IH/bin' PATH='$IH/fakebin:/usr/bin:/bin' AW_RAW_URL='file://$AW' sh < '$SRC_DIR/install.sh'" /dev/null >/dev/null 2>&1
    if [ -f "$IH/.claude/skills/agent-worker/SKILL.md" ]; then ok "파이프 설치에서 y 로 고른 곳엔 넣음"; else ng "y 라 했는데 안 넣음"; fi
    if [ -e "$IH/.gemini" ]; then ng "Enter(기본 아니오)인데 넣음"; else ok "그냥 Enter 면 넣지 않음 (기본 아니오)"; fi
  fi
else
  echo "  (curl 없음: 파이프 설치 시험 생략)"
fi

head_ "17. 설치 점검 (aw setup)"
fresh; fake codex
out=$(env HOME="$IH" PATH="$IH/fakebin:/usr/bin:/bin" AW_DEFAULTS="$IH/defaults" "$AW" setup < /dev/null 2>&1)
for want in "[1/5] 기본 옵션" "[2/5] 워커 지시문" "[3/5] 에이전트 CLI" "[4/5] 에이전트 스킬" "[5/5] PATH" "아무것도 바꾸지 않습니다"; do
  case "$out" in *"$want"*) ok "점검 출력에 '$want'" ;; *) ng "점검 출력에 '$want' 없음" ;; esac
done
if [ -e "$IH/defaults" ] || [ -e "$IH/.agents" ]; then ng "터미널이 아닌데 무언가를 바꿈"; else ok "터미널이 아니면 아무것도 바꾸지 않음"; fi
if command -v script >/dev/null 2>&1 && script -qec true /dev/null >/dev/null 2>&1; then
  # 가상 터미널로 답을 넣습니다: 권한 옵션은 n, 스킬은 y
  fresh; fake codex
  printf 'n\nn\ny\n' | script -qec "env HOME='$IH' PATH='$IH/fakebin:/usr/bin:/bin' AW_DEFAULTS='$IH/defaults' AW_BRIEF='$IH/brief' '$AW' setup" /dev/null >/dev/null 2>&1
  if [ -e "$IH/defaults" ]; then ng "n 이라 했는데 권한 옵션을 켬"; else ok "권한 옵션은 n 이면 켜지 않음"; fi
  if [ -f "$IH/.agents/skills/agent-worker/SKILL.md" ]; then ok "스킬은 y 면 넣음"; else ng "y 라 했는데 스킬을 안 넣음"; fi
  fresh; fake codex
  printf 'y\n\n\n' | script -qec "env HOME='$IH' PATH='$IH/fakebin:/usr/bin:/bin' AW_DEFAULTS='$IH/defaults' AW_BRIEF='$IH/brief' '$AW' setup" /dev/null >/dev/null 2>&1
  if [ -f "$IH/defaults" ]; then ok "권한 옵션은 y 면 켬"; else ng "y 라 했는데 권한 옵션을 안 켬"; fi
  if [ -e "$IH/.agents" ]; then ng "Enter(기본 아니오)인데 스킬을 넣음"; else ok "새 스킬은 그냥 Enter 면 넣지 않음 (기본 아니오)"; fi
  if [ -f "$IH/brief" ]; then ok "지시문은 그냥 Enter 면 켬 (기본 예)"; else ng "Enter 인데 지시문을 안 켬"; fi
  # 이미 넣은 스킬을 새 버전으로 바꾸는 건 기본 예
  fresh; fake codex
  awh skill install >/dev/null 2>&1; printf '추가된 줄\n' >> "$IH/.agents/skills/agent-worker/SKILL.md"
  printf '\n\n\n' | script -qec "env HOME='$IH' PATH='$IH/fakebin:/usr/bin:/bin' AW_DEFAULTS='$IH/defaults' AW_BRIEF='$IH/brief' '$AW' setup" /dev/null >/dev/null 2>&1
  check "옛 버전은 그냥 Enter 면 최신으로 (기본 예)" 최신 "$(state_of_agent codex)"
else
  echo "  (script 없음: 대화형 점검 시험 생략)"
fi

head_ "18. 진행 상황 (aw peek / aw watch)"

# 에이전트는 명령을 따로 떼어 띄웁니다. 프로세스 그룹이 아니라 부모-자식으로 따라가야 보입니다.
"$AW" run -n pk-tree -- sh -c 'sh -c "sleep 7; true"; true' >/dev/null 2>&1
sleep 1
out=$("$AW" peek pk-tree)
has "지금 도는 하위 명령이 보임" "$out" "지금 실행 중: sleep 7"
if command -v bash >/dev/null 2>&1; then
  "$AW" run -n pk-mcp -- bash -c '(exec -a "node kordoc mcp" sleep 7) & sleep 6; wait' >/dev/null 2>&1
  sleep 1
  out=$("$AW" peek pk-mcp)
  has "MCP 도우미를 걸러도 진짜 명령은 보임" "$out" "sleep 6"
  hasnt "MCP 도우미는 지금 실행 중에서 뺌" "$out" "kordoc mcp"
  # kiro-cli v3 엔진은 처음부터 node .../acp-server.js 를 띄워 둡니다 (실측)
  "$AW" run -n pk-acp -- bash -c '(exec -a "node /k/kas/dist/server/acp-server.js --transport=stdio" sleep 7) & sleep 6; wait' >/dev/null 2>&1
  sleep 1
  out=$("$AW" peek pk-acp)
  has "ACP 도우미를 걸러도 진짜 명령은 보임" "$out" "sleep 6"
  hasnt "kiro-cli 의 acp-server 는 지금 실행 중에서 뺌" "$out" "acp-server"
fi

# 출력 형식 셋: 내용으로 알아보고 사람이 읽을 줄로 풉니다
cl='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"테스트를 돌려 보겠습니다."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"npm test -- auth","description":"테스트"}}]}}'
"$AW" run -n pk-claude -- sh -c 'printf "%s\n" "$1" "$1"; sleep 5; true' sh "$cl" >/dev/null 2>&1
cx='{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/usr/bin/zsh -lc '"'"'pytest -q'"'"'","status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"/r/src/a.py","kind":"update"}],"status":"completed"}}
{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"고쳤습니다"}}'
"$AW" run -n pk-codex -- sh -c 'printf "%s\n" "$1"; sleep 5; true' sh "$cx" >/dev/null 2>&1
ag='{"event":"step_update","step_update":{"step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"go test ./..."}}}}'
"$AW" run -n pk-agy -- sh -c 'printf "%s\n" "$1"; sleep 5; true' sh "$ag" >/dev/null 2>&1
# kiro-cli stream-json (실측한 모양): tool_call 의 제목과 첫 입력값. tool_call_update 는 같은 호출이라 뺌
kr='{"type":"sessionUpdate","data":{"sessionId":"K1","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Creating a.txt","kind":"edit","rawInput":{"__tool_use_purpose":"a.txt 를 만듦","command":"create","path":"a.txt"}}}}
{"type":"sessionUpdate","data":{"sessionId":"K1","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","title":"Creating a.txt"}}}
{"type":"sessionUpdate","data":{"sessionId":"K1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"다 "}}}}
{"type":"sessionUpdate","data":{"sessionId":"K1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"했습니다"}}}}'
kf='{"type":"runFinished","data":{"sessionId":"K1","status":"success","stopReason":"end_turn","finalText":"다 했습니다","finalTextTruncated":false}}'
"$AW" run -n pk-kiro -- sh -c 'printf "%s\n" "$1"; sleep 4; printf "%s\n" "$2"' sh "$kr" "$kf" >/dev/null 2>&1
sleep 1
out=$("$AW" peek pk-claude)
has "claude: 도구 호출" "$out" "npm test -- auth"
has "claude: 말" "$out" "테스트를 돌려 보겠습니다."
check "claude: 같은 호출(같은 id)은 한 번만" 1 "$(printf '%s\n' "$out" | grep -c 'npm test')"
out=$("$AW" peek pk-codex)
has "codex: 명령 (셸 감싸기를 벗김)" "$out" "명령     pytest -q"
has "codex: 바뀐 파일" "$out" "/r/src/a.py"
has "codex: 말" "$out" "고쳤습니다"
out=$("$AW" peek pk-agy)
has "agy: 도구 단계" "$out" "run_command go test ./..."
out=$("$AW" peek pk-kiro)
has "kiro-cli: 도구 호출의 제목과 입력" "$out" "Creating a.txt a.txt 를 만듦"
has "kiro-cli: 아직 쓰는 중인 답 조각도 말로 이어 붙임" "$out" "말       다 했습니다"
check "kiro-cli: tool_call_update 는 따로 안 셈" 1 "$(printf '%s\n' "$out" | grep -c 'Creating a.txt')"
hasnt "kiro-cli: JSON 을 날것으로 보이지 않음" "$out" '"sessionUpdate"'
"$AW" wait pk-kiro --timeout 20 >/dev/null 2>&1
has "kiro-cli: 끝나면 답은 이어 붙인 마지막 말 (text 조각이 아니라)" "$("$AW" peek pk-kiro)" "답          : 다 했습니다"

# agy·kiro-cli 는 답을 몇 글자씩 조각으로 보냅니다 (실측). 도구 호출·생각·단계 끝에서 끊어 말 한 줄로 이어 붙입니다.
kc='{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"예상 "}}}}
{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"session_info_update","_meta":{"kiro":{"kind":"context_usage"}}}}}
{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"소요: 약 7분\n"}}}}
{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Wait (1/2)","rawInput":{"command":"sleep 75"}}}}
{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"1회차 완료, "}}}}
{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"2회차 실행 중입니다."}}}}
{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"생각"}}}}
{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"끝"}}}}
{"type":"runFinished","data":{"status":"success","stopReason":"end_turn","finalText":"예상 소요: 약 7분\n1회차 완료, 2회차 실행 중입니다.끝"}}'
# 답을 마지막 말로 고르는 건 kiro-cli 워커일 때만이라, 출력을 그대로 내는 가짜 kiro-cli 로 띄웁니다.
mkdir -p "$TMPROOT/kbin"; printf '%s\n' "$kc" > "$TMPROOT/kc.jsonl"
printf '#!/bin/sh\ncat "%s"\n' "$TMPROOT/kc.jsonl" > "$TMPROOT/kbin/kiro-cli"; chmod +x "$TMPROOT/kbin/kiro-cli"
PATH="$TMPROOT/kbin:$PATH" "$AW" run -n pk-kchunk --no-defaults -- kiro-cli chat 질문 >/dev/null 2>&1
ac='{"event":"step_update","step_update":{"step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":"먼저 "}}
{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","text_delta":"보겠습니다\n"}}
{"event":"step_update","step_update":{"step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"ls"}}}}
{"event":"step_update","step_update":{"step_index":3,"state":"ACTIVE","step_type":"agent_response","text_delta":"다 "}}
{"event":"step_update","step_update":{"step_index":4,"state":"ACTIVE","step_type":"agent_response","text_delta":"새 단계"}}'
"$AW" run -n pk-achunk -- sh -c 'printf "%s\n" "$1"' sh "$ac" >/dev/null 2>&1
"$AW" wait pk-kchunk pk-achunk --timeout 20 >/dev/null 2>&1
check "kiro-cli: 조각을 이어 붙이고 도구 호출·생각에서 끊음 (다른 사건은 건너뜀)" \
  "$(printf '말       예상 소요: 약 7분\nWait (1/2) sleep 75\n말       1회차 완료, 2회차 실행 중입니다.\n말       끝')" \
  "$("$AW" peek pk-kchunk -n 10 | sed -n '/최근 활동/,/답/p' | sed '1d;$d' | sed 's/^    //')"
has "kiro-cli: 답은 진행 줄까지 붙은 finalText 가 아니라 마지막 말" "$("$AW" peek pk-kchunk)" "답          : 끝"
check "agy: 단계(step_index)마다, DONE 이나 도구 단계에서 끊음" \
  "$(printf '말       먼저 보겠습니다\nrun_command ls\n말       다\n말       새 단계')" \
  "$("$AW" peek pk-achunk -n 10 | sed -n '/최근 활동/,/결과/p' | sed '1d;$d' | sed 's/^    //')"

# claude 를 json 으로 띄우면 출력이 끝날 때까지 비어 있습니다. 도는 동안 claude 가
# sessions/<pid>.json 에 적는 세션 ID 로 대화 기록을 찾아 읽습니다.
fresh
cat > "$IH/fakebin/claude" <<'FAKE'
#!/bin/sh
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/-work"
printf '{"pid":%s,"sessionId":"sess-123","cwd":"/work"}\n' "$$" > "$HOME/.claude/sessions/$$.json"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"src/login.ts"}}]}}' \
  > "$HOME/.claude/projects/-work/sess-123.jsonl"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t9","name":"Read","input":{"file_path":"다른세션.ts"}}]}}' \
  > "$HOME/.claude/projects/-work/other-session.jsonl"
sleep 5
rm -f "$HOME/.claude/sessions/$$.json"
printf '%s\n' '{"type":"result","result":"끝","session_id":"sess-123"}'
FAKE
chmod +x "$IH/fakebin/claude"
env HOME="$IH" PATH="$IH/fakebin:$PATH" "$AW" run -n pk-cj --no-defaults -- claude -p --output-format json "로그인 고쳐줘" >/dev/null 2>&1
sleep 2
out=$(env HOME="$IH" "$AW" peek pk-cj)
has "claude json: 대화 기록에서 활동을 읽음" "$out" "claude 대화 기록에서"
has "claude json: 그 워커의 기록 (pid 로 찾음)" "$out" "src/login.ts"
hasnt "claude json: 다른 세션 기록은 안 읽음" "$out" "다른세션.ts"
"$AW" wait pk-cj --timeout 20 >/dev/null 2>&1
out=$(env HOME="$IH" "$AW" peek pk-cj)
has "끝난 claude json 도 meta 의 세션 ID 로 기록을 찾음" "$out" "src/login.ts"
has "끝난 워커는 최종 답을 보여 줌" "$out" "답          : 끝"
hasnt "끝난 워커의 JSON 을 날것으로 보이지 않음" "$out" '"type":"result"'

# 모르는 형식은 마지막 줄 그대로, 긴 줄은 UTF-8 글자를 자르지 않고 줄임
long=$(printf '가나다라마바사아자차카타파하%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)
"$AW" run -n pk-text -- sh -c 'echo "빌드 1단계"; echo "$1"; echo "빌드 2단계"; sleep 5; true' sh "$long" >/dev/null 2>&1
sleep 1
out=$("$AW" peek pk-text)
has "텍스트 출력은 마지막 줄들을 그대로" "$out" "빌드 2단계"
has "긴 줄은 줄임표로 줄임" "$out" "…"
if command -v iconv >/dev/null 2>&1; then
  if printf '%s\n' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then ok "줄여도 UTF-8 이 깨지지 않음"; else ng "줄이다 UTF-8 글자를 반으로 자름"; fi
fi

# 줄바꿈 없이 한 줄로 길게 쌓이는 텍스트(실측: devin)는 앞이 아니라 끝을 보여 줘야 합니다
oneline=$(printf '처음문장입니다. %.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)
"$AW" run -n pk-oneline -- sh -c 'printf "%s" "$1"; printf "%s" "마지막문장"; sleep 5; true' sh "$oneline" >/dev/null 2>&1
sleep 1
out=$("$AW" peek pk-oneline)
has "한 줄로 긴 텍스트는 끝(최신)을 보여 줌" "$out" "마지막문장"
out=$("$AW" peek)
has "짧게 볼 때도 끝을 보여 줌" "$(printf '%s\n' "$out" | grep -A2 '^pk-oneline')" "마지막문장"
if command -v iconv >/dev/null 2>&1; then
  if printf '%s\n' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then ok "끝을 남겨도 UTF-8 이 깨지지 않음"; else ng "끝을 남기다 UTF-8 글자를 반으로 자름"; fi
fi

# worktree 에서 바뀐 파일 수
"$AW" run -n pk-wt -d "$REPO" -w feat/pk -- sh -c 'printf "a\n" > new.txt; sleep 5; true' >/dev/null 2>&1
sleep 1
out=$("$AW" peek pk-wt)
has "worktree 의 새 파일 수" "$out" "파일 1개 바뀜 (새 파일 1개)"

# 이름을 빼면 실행 중인 워커를 짧게, 끝난 워커는 빠짐
"$AW" run -n pk-long -- sh -c 'sleep 15; true' >/dev/null 2>&1
"$AW" run -n pk-done -- true >/dev/null 2>&1
"$AW" wait pk-done >/dev/null 2>&1
out=$("$AW" peek)
has "aw peek 은 실행 중인 워커를 보여 줌" "$out" "pk-long  running"
hasnt "aw peek 은 끝난 워커를 빼고 보여 줌" "$out" "pk-done"
out=$("$AW" peek pk-done)
has "끝난 워커를 이름으로 보면 결과 안내" "$out" "aw result pk-done"
if "$AW" peek nobody >/dev/null 2>&1; then ng "없는 워커를 peek 함"; else ok "없는 워커는 거절"; fi

# macOS 의 ps 는 etimes 가 없고 etime([[일-]시:]분:초) 만 줍니다. 그 경로를 가짜 ps 로 흉내 냅니다.
"$AW" run -n pk-mac -- sh -c 'sleep 6; true' >/dev/null 2>&1
sleep 1
mpid=$(cat "$AW_HOME/workers/pk-mac/pid")
mkdir -p "$TMPROOT/macps"
cat > "$TMPROOT/macps/ps" <<FAKE
#!/bin/sh
# 실제 macOS 처럼: 모르는 열이 있으면 오류와 함께 나머지 열로 출력하고 1 로 끝남
case "\$*" in *etimes*) echo "ps: etimes: keyword not found" >&2; printf '%s\n' "$mpid 1 sh -c sleep" "99999 $mpid make build"; exit 1 ;; esac
printf '%s\n' "$mpid 1 05:00 sh -c sleep" "99999 $mpid 1-02:03:04 make build"
FAKE
chmod +x "$TMPROOT/macps/ps"
out=$(PATH="$TMPROOT/macps:$PATH" "$AW" peek pk-mac)
has "etimes 가 없으면 etime 으로 (일-시:분:초 → 26h3m)" "$out" "make build   (26h3m)"
hasnt "etimes 로 밀린 출력은 쓰지 않음" "$out" "실행 중: build"

# watch: 터미널이 아니면 지우지 않고 이어 쓰고, 다 끝나면 스스로 멈춤 (timeout 명령 없이)
"$AW" run -n pk-watch -- sh -c 'sleep 2; true' >/dev/null 2>&1
rm -f "$TMPROOT/watch.rc"
( "$AW" watch pk-watch -i 1 > "$TMPROOT/watch.out" 2>&1; echo $? > "$TMPROOT/watch.rc" ) &
wpid=$!; i=0
while [ ! -f "$TMPROOT/watch.rc" ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
kill "$wpid" 2>/dev/null
check "watch 는 워커가 끝나면 0 으로 멈춤" 0 "$(cat "$TMPROOT/watch.rc" 2>/dev/null || echo 시간초과)"
has "watch 가 끝났다고 알림" "$(cat "$TMPROOT/watch.out")" "모두 끝났습니다"
"$AW" stop pk-long >/dev/null 2>&1
"$AW" wait pk-tree pk-claude pk-codex pk-agy pk-kiro pk-text pk-oneline pk-wt pk-mac --timeout 20 >/dev/null 2>&1
[ -n "$(command -v bash)" ] && "$AW" wait pk-mcp pk-acp --timeout 20 >/dev/null 2>&1
"$AW" clean >/dev/null 2>&1

head_ "19. 생각 중 / 조용함 (peek, wait --idle)"
# claude stream-json: 생각하는 동안 몇 초마다 thinking_tokens 줄이 나옵니다 (실측)
fresh
cat > "$IH/fakebin/claude" <<'FAKE'
#!/bin/sh
printf '%s\n' '{"type":"system","subtype":"init","session_id":"s1"}' \
  '{"type":"system","subtype":"thinking_tokens","estimated_tokens":50,"estimated_tokens_delta":50}' \
  '{"type":"system","subtype":"thinking_tokens","estimated_tokens":1200,"estimated_tokens_delta":150}'
sleep 6
FAKE
chmod +x "$IH/fakebin/claude"
env HOME="$IH" PATH="$IH/fakebin:$PATH" "$AW" run -n th-claude --no-defaults -- claude -p --output-format stream-json --verbose "생각" >/dev/null 2>&1
sleep 1
out=$(env HOME="$IH" "$AW" peek th-claude)
has "claude: 생각 중 토큰 수" "$out" "생각 중     : 약 1200 토큰째"

# kiro-cli(v3): 생각 내용이 agent_thought_chunk 조각으로 출력에 흐릅니다 (실측)
cat > "$IH/fakebin/kiro-cli" <<'FAKE'
#!/bin/sh
printf '%s\n' '{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"옛 생각"}}}}' \
  '{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"중간 답"}}}}' \
  '{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"abc"}}}}' \
  '{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"session_info_update","_meta":{"kiro":{"kind":"context_usage"}}}}}' \
  '{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"한글\"x"}}}}'
sleep 6
FAKE
chmod +x "$IH/fakebin/kiro-cli"
env HOME="$IH" PATH="$IH/fakebin:$PATH" "$AW" run -n th-kiro --no-defaults -- kiro-cli chat --output-format stream-json "생각" >/dev/null 2>&1
sleep 1
out=$(env HOME="$IH" "$AW" peek th-kiro)
has "kiro-cli: 지금 이어지는 생각의 글자 수 (앞선 생각은 빼고, 사이 사건은 건너뜀)" "$out" "생각 중     : 약 7자째"
hasnt "kiro-cli: 생각 내용은 말로 보이지 않음" "$out" "abc"

# kiro-cli: 모델이 거절해 멈춰도 success·코드 0 입니다. 사유는 turn_end 에만 남습니다 (실측)
cat > "$IH/fakebin/kiro-cli" <<'FAKE'
#!/bin/sh
printf '%s\n' '{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"The selected model cannot continue this conversation."}}}}' \
  '{"type":"sessionUpdate","data":{"update":{"sessionUpdate":"session_info_update","_meta":{"kiro":{"turnEnd":{"stopReason":"content_filtered"},"kind":"turn_end","stopReason":"content_filtered","stopDetails":{"refusal":{"category":"REASONING_EXTRACTION","explanation":"x"}}}}}}}' \
  '{"type":"runFinished","data":{"status":"success","stopReason":"end_turn","finalText":"The selected model cannot continue this conversation."}}'
FAKE
env HOME="$IH" PATH="$IH/fakebin:$PATH" "$AW" run -n kr-refused --no-defaults -- kiro-cli chat --output-format stream-json "생각" >/dev/null 2>&1
"$AW" wait kr-refused --timeout 10 >/dev/null 2>&1
check "kiro-cli: 거절당해도 코드 0 (그대로 전함)" 0 "$(cat "$AW_HOME/workers/kr-refused/exit")"
out=$("$AW" peek kr-refused)
has "kiro-cli: 거절로 멈췄다고 사유와 함께 알림" "$out" "주의        : 모델이 거절해 도중에 멈췄습니다 (content_filtered, REASONING_EXTRACTION)"
has "kiro-cli: 생각 빼내기면 지시문을 보라고 알림" "$out" "지시문(aw brief)"
printf '%s\n' '#!/bin/sh' "printf '%s\\n' '{\"type\":\"runFinished\",\"data\":{\"status\":\"success\",\"stopReason\":\"end_turn\",\"finalText\":\"정상 답\"}}'" > "$IH/fakebin/kiro-cli"
env HOME="$IH" PATH="$IH/fakebin:$PATH" "$AW" run -n kr-ok --no-defaults -- kiro-cli chat --output-format stream-json "질문" >/dev/null 2>&1
"$AW" wait kr-ok --timeout 10 >/dev/null 2>&1
out=$("$AW" peek kr-ok)
has "정상으로 끝난 kiro-cli 의 답" "$out" "답          : 정상 답"
hasnt "정상으로 끝난 kiro-cli 에는 주의가 없음" "$out" "주의        :"

# codex: 출력은 조용하지만 자기 세션 파일에 추론 단계가 쌓입니다 (실측)
cat > "$IH/fakebin/codex" <<'FAKE'
#!/bin/sh
printf '%s\n' '{"type":"thread.started","thread_id":"T-abc-123"}' '{"type":"turn.started"}'
d="$HOME/.codex/sessions/2026/09/24"; mkdir -p "$d"
# 세션 파일은 마지막 명령(sleep 7)이 뜬 뒤에 씁니다. 그래야 마지막 활동의 출처가 이 파일입니다.
( sleep 2
  printf '%s\n' '{"timestamp":"t","type":"event_msg","payload":{"type":"user_message"}}' \
    '{"timestamp":"t","type":"response_item","payload":{"type":"reasoning","summary":[]}}' \
    '{"timestamp":"t","type":"event_msg","payload":{"type":"token_count"}}' \
    '{"timestamp":"t","type":"response_item","payload":{"type":"reasoning","summary":[]}}' \
    '{"timestamp":"t","type":"response_item","payload":{"type":"reasoning","summary":[]}}' > "$d/rollout-2026-T-abc-123.jsonl" ) &
sleep 7
FAKE
chmod +x "$IH/fakebin/codex"
env HOME="$IH" PATH="$IH/fakebin:$PATH" "$AW" run -n th-codex --no-defaults -- codex exec --json "생각" >/dev/null 2>&1
sleep 4
out=$(env -u CODEX_HOME HOME="$IH" "$AW" peek th-codex)
has "codex: 세션 파일의 추론 단계 수" "$out" "추론 3단계"
has "codex: 세션 파일도 활동으로 침" "$out" "(codex 기록)"
hasnt "codex: 남은 JSON 사건 줄을 날것으로 보이지 않음" "$out" "thread.started"

# codex 출력의 앞 4096 바이트가 한글 가운데서 잘려도 스레드 ID 를 온전히 꺼냅니다. 예전에는 ID 뒤에
# 깨진 바이트가 붙어 세션 파일을 못 찾았고, gawk 가 Invalid multibyte data 경고를 냈습니다.
l1='{"type":"thread.started","thread_id":"T-mb-456"}'; l2='{"type":"turn.started"}'
pre='{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"'
pad=''; while [ $(( (4096 - ${#l1} - ${#l2} - 2 - ${#pre} - ${#pad}) % 3 )) -ne 1 ]; do pad="${pad}x"; done
ko=''; i=0; while [ "$i" -lt 1500 ]; do ko="${ko}가"; i=$((i + 1)); done
printf '%s\n%s\n%s%s%s"}}\n' "$l1" "$l2" "$pre" "$pad" "$ko" > "$IH/codex-mb.out"
cat > "$IH/fakebin/codex" <<FAKE
#!/bin/sh
cat '$IH/codex-mb.out'
d="\$HOME/.codex/sessions/2026/09/29"; mkdir -p "\$d"
( sleep 2; printf '%s\n' '{"timestamp":"t","type":"response_item","payload":{"type":"reasoning","summary":[]}}' > "\$d/rollout-2026-T-mb-456.jsonl" ) &
sleep 7
FAKE
chmod +x "$IH/fakebin/codex"
env HOME="$IH" PATH="$IH/fakebin:$PATH" "$AW" run -n th-codex-mb --no-defaults -- codex exec --json "생각" >/dev/null 2>&1
sleep 4
out=$(env -u CODEX_HOME HOME="$IH" "$AW" peek th-codex-mb 2>&1)
has "codex: 앞 4096 바이트가 한글 가운데서 잘려도 세션 파일을 찾음" "$out" "추론 1단계"
hasnt "codex: 깨진 바이트로 awk 경고를 내지 않음" "$out" "multibyte"

# 텍스트 출력이 64KB 를 넘고 한글 가운데서 잘려도, 최근 출력과 예상 소요 시간을 읽습니다.
# 예전에는 GNU grep 이 깨진 첫 바이트를 보고 "binary file matches" 한 줄만 냈습니다.
"$AW" run -n mb-text -- sh -c 'i=0; while [ $i -lt 4000 ]; do echo "한글 진행 줄입니다."; i=$((i+1)); done; echo "예상 소요: 약 15분"; echo "마지막 줄입니다"; sleep 6' >/dev/null 2>&1
sleep 2
out=$("$AW" peek mb-text 2>&1)
hasnt "텍스트: 잘린 한글에 binary file matches 가 나오지 않음" "$out" "binary file"
has "텍스트: 최근 출력의 마지막 줄" "$out" "마지막 줄입니다"
has "텍스트: 예상 소요 시간을 읽음" "$out" "약 15분"
"$AW" wait th-codex-mb mb-text --timeout 20 >/dev/null 2>&1

# 마지막 활동의 출처: 새로 뜬 하위 명령, 작업 폴더의 파일 변경
"$AW" run -n la-cmd -- sh -c 'sleep 2; sh -c "sleep 8; true"; true' >/dev/null 2>&1
"$AW" run -n la-file -d "$REPO" -w feat/la -- sh -c '(sleep 2; printf x > f.txt) & sleep 9; true' >/dev/null 2>&1
sleep 4
has "새로 뜬 명령이 활동" "$("$AW" peek la-cmd)" "(새 명령)"
has "작업 폴더의 파일 변경이 활동" "$("$AW" peek la-file)" "(파일 변경)"

# 오래 조용하면 알림 (AW_QUIET 초)
"$AW" run -n q-quiet -- sh -c 'echo 시작; sleep 9; true' >/dev/null 2>&1
"$AW" run -n q-busy -- sh -c 'for i in 1 2 3 4 5 6 7 8; do echo "$i"; sleep 1; done' >/dev/null 2>&1
sleep 4
has "조용하면 조용함을 알림" "$(AW_QUIET=2 "$AW" peek q-quiet)" "조용함"
hasnt "계속 출력하면 조용함이 아님" "$(AW_QUIET=5 "$AW" peek q-busy)" "조용함"

# wait --idle: 조용하면 3 으로 돌아오고 워커는 그대로, 바쁘면 끝까지 기다림
"$AW" run -n idle-w -- sh -c 'sleep 12; true' >/dev/null 2>&1
"$AW" wait idle-w --idle 2 >/dev/null 2>&1; rc=$?
check "wait --idle: 조용하면 코드 3" 3 "$rc"
state=$("$AW" list --json | sed -n 's/.*"name":"idle-w","state":"\([a-z]*\)".*/\1/p')
check "wait --idle 은 워커를 끊지 않음" running "$state"
"$AW" run -n busy-w -- sh -c 'for i in 1 2 3 4 5 6; do echo "$i"; sleep 1; done' >/dev/null 2>&1
"$AW" wait busy-w --idle 5 >/dev/null 2>&1; rc=$?
check "wait --idle: 계속 신호가 있으면 끝까지 (코드 0)" 0 "$rc"
"$AW" stop idle-w >/dev/null 2>&1

# 끝난 워커의 worktree 를 누군가 이어서 고쳐도, 그건 이 워커의 활동이 아닙니다
"$AW" run -n fin-wt -d "$REPO" -w feat/fin -- sh -c 'echo 끝' >/dev/null 2>&1
"$AW" wait fin-wt >/dev/null 2>&1
sleep 3
: > "$REPO/.aw-worktrees/fin-wt/late.txt"
out=$("$AW" peek fin-wt)
has "끝난 워커의 마지막 활동은 끝나기 전 것" "$out" "(출력)"
hasnt "끝난 뒤의 파일 변경은 세지 않음" "$out" "(파일 변경)"
"$AW" wait th-claude th-codex la-cmd la-file q-quiet q-busy --timeout 20 >/dev/null 2>&1
"$AW" clean >/dev/null 2>&1

head_ "20. 워커 지시문 (brief)"
fresh
# 가짜 에이전트: 받은 인자와 표준 입력을 그대로 찍습니다 (devin 은 --prompt-file 내용도)
for a in claude codex agy kiro-cli; do
  printf '%s\n' '#!/bin/sh' 'printf "[%s]\n" "$@"' 'cat' 'printf "%s\n" "{\"session_id\":\"S1\"}"' > "$IH/fakebin/$a"
done
cat > "$IH/fakebin/devin" <<'FAKE'
#!/bin/sh
printf '[%s]\n' "$@"
nxt=''
for a in "$@"; do
  [ "$nxt" = f ] && { echo "<파일>"; cat "$a"; }
  nxt=''
  case "$a" in --prompt-file) nxt=f ;; --prompt-file=*) echo "<파일>"; cat "${a#--prompt-file=}" ;; esac
done
FAKE
chmod +x "$IH/fakebin/"*
printf '# 이 줄은 안 붙음\n\n예상 소요를 먼저 적으세요.\n' > "$IH/brief"
B='예상 소요를 먼저 적으세요.'
bw() { env AW_BRIEF="$IH/brief" PATH="$IH/fakebin:$PATH" "$AW" "$@"; }
bres() { "$AW" wait "$1" >/dev/null 2>&1; "$AW" result "$1"; }

out=$(bw run -n br-claude --no-defaults -- claude -p "작업" 2>&1)
has "run 출력에 지시문이 붙었다고 알림" "$out" "지시문이 붙었습니다"
check "claude: 맨 끝 프롬프트 앞에 붙음" "$(printf '[-p]\n[%s\n\n작업]' "$B")" "$(bres br-claude | sed '$d')"
check "cmd.orig 에는 붙이기 전 인자" 작업 "$(tail -1 "$AW_HOME/workers/br-claude/cmd.orig")"
hasnt "'#' 줄은 붙지 않음" "$(bres br-claude)" "이 줄은 안 붙음"
bw run -n br-agy-eq --no-defaults -- agy --output-format json -p='작업' >/dev/null 2>&1
has "agy: -p= 값 앞에 붙음" "$(bres br-agy-eq)" "[-p=$B"
bw run -n br-agy-sp --no-defaults -- agy -p '작업' --model m >/dev/null 2>&1
check "agy: -p 다음 값 앞에 붙음" "$(printf '[-p]\n[%s\n\n작업]\n[--model]\n[m]' "$B")" "$(bres br-agy-sp | sed '$d')"
bw run -n br-devin --no-defaults -- devin -p "작업" --model m >/dev/null 2>&1
has "devin: -p 다음 프롬프트 앞에 붙음" "$(bres br-devin)" "[$B"
printf '사양 내용\n' > "$TMPROOT/spec.md"
bw run -n br-devin-f --no-defaults -- devin -p --prompt-file "$TMPROOT/spec.md" >/dev/null 2>&1
check "devin: --prompt-file 은 지시문을 앞에 붙인 새 파일로" "$(printf '<파일>\n%s\n\n사양 내용' "$B")" "$(bres br-devin-f | sed -n '/<파일>/,$p')"
check "devin: 원래 사양 파일은 그대로" "사양 내용" "$(cat "$TMPROOT/spec.md")"
bw run -n br-stdin --no-defaults -f "$TMPROOT/spec.md" -- claude -p >/dev/null 2>&1
check "-f 로 넣은 표준 입력 앞에 붙음" "$(printf '[-p]\n%s\n\n사양 내용' "$B")" "$(bres br-stdin | sed '$d')"
bw run -n br-codex --no-defaults -f "$TMPROOT/spec.md" -- codex exec --json - >/dev/null 2>&1
has "codex: - (표준 입력) 앞에 붙음" "$(bres br-codex)" "$B"
bw run -n br-kiro --no-defaults -- kiro-cli chat --output-format stream-json "작업" >/dev/null 2>&1
check "kiro-cli: 맨 끝 프롬프트 앞에 붙음" "$(printf '[chat]\n[--output-format]\n[stream-json]\n[%s\n\n작업]' "$B")" "$(bres br-kiro | sed '$d')"
out=$(bw run -n br-kiro-none --no-defaults -- kiro-cli chat 2>&1)
hasnt "kiro-cli: chat 을 프롬프트로 알지 않음" "$out" "지시문이 붙었습니다"
bw run -n br-kiro-f --no-defaults -f "$TMPROOT/spec.md" -- kiro-cli chat --output-format stream-json >/dev/null 2>&1
has "kiro-cli: -f 로 넣은 표준 입력 앞에 붙음" "$(bres br-kiro-f)" "$(printf '%s\n\n사양 내용' "$B")"
bw run -n br-off --no-defaults --no-brief -- claude -p "작업" >/dev/null 2>&1
check "--no-brief 면 안 붙음" "$(printf '[-p]\n[작업]')" "$(bres br-off | sed '$d')"
AW_NO_BRIEF=1 bw run -n br-off2 --no-defaults -- claude -p "작업" >/dev/null 2>&1
check "AW_NO_BRIEF=1 이면 안 붙음" "$(printf '[-p]\n[작업]')" "$(bres br-off2 | sed '$d')"
out=$(bw run -n br-other -- sh -c 'echo "$1"' sh "작업" 2>&1)
hasnt "모르는 명령에는 붙이지 않음" "$out" "지시문이 붙었습니다"
check "모르는 명령의 인자는 그대로" 작업 "$(bres br-other)"
env AW_BRIEF="$IH/없음" PATH="$IH/fakebin:$PATH" "$AW" run -n br-none --no-defaults -- claude -p "작업" >/dev/null 2>&1
check "지시문 파일이 없으면 안 붙음" "$(printf '[-p]\n[작업]')" "$(bres br-none | sed '$d')"
# 이어하기: 새 프롬프트에 한 번만 붙음 (옛 프롬프트와 옛 지시문은 걷어냄)
bw resume br-claude -- '다음' >/dev/null 2>&1
out=$(bres br-claude-r1)
check "이어하기에도 지시문이 한 번만" 1 "$(printf '%s\n' "$out" | grep -c "$B")"
has "이어하기는 새 프롬프트에 붙음" "$out" "$(printf '%s\n\n다음]' "$B")"
hasnt "이어하기에 옛 프롬프트가 안 남음" "$out" "작업"

# aw brief
out=$(env AW_BRIEF="$IH/b2" "$AW" brief)
has "지시문이 없으면 꺼져 있다고 알림" "$out" "꺼져 있습니다"
env AW_BRIEF="$IH/b2" "$AW" brief --init >/dev/null 2>&1
if [ -f "$IH/b2" ]; then ok "aw brief --init 이 권장값을 씀"; else ng "aw brief --init 이 파일을 안 만듦"; fi
has "권장값은 예상 소요 시간을 묻음" "$(env AW_BRIEF="$IH/b2" "$AW" brief)" "예상 소요"
printf '내 지시문\n' > "$IH/b2"; env AW_BRIEF="$IH/b2" "$AW" brief --init >/dev/null 2>&1
check "aw brief --init 은 있던 것을 덮어쓰지 않음" "내 지시문" "$(cat "$IH/b2")"
has "권장 예시에는 숫자가 없음 (답으로 잘못 읽지 않게)" "$(env AW_BRIEF="$IH/b3" "$AW" brief | grep '예상 소요:')" '약 N분'
# 생각 과정을 적어 내라는 문장은 kiro-cli 가 생각 빼내기로 보고 거절합니다 (실측). 권장값에 없어야 하고,
# 예전 권장값을 쓰는 사람에게는 알립니다.
env AW_BRIEF="$IH/b4" "$AW" brief --init >/dev/null 2>&1
hasnt "권장값에 생각 과정을 적으라는 문장이 없음" "$(cat "$IH/b4")" "생각하지 말고"
hasnt "새 권장값이면 예전 지시문 알림이 없음" "$(env AW_BRIEF="$IH/b4" "$AW" brief)" "주의:"
printf '%s\n' '작업이 5분 넘게 걸리면 몇 분마다 지금 하는 일을 한 줄로 적으세요. 오래 생각해야 할 때도 한 번에 다 생각하지 말고, 중간에 한 줄씩 진행을 남기며 이어 가세요.' > "$IH/b5"
has "예전 지시문이면 aw brief 가 알림" "$(env AW_BRIEF="$IH/b5" "$AW" brief)" "aw brief --init --force"
has "예전 지시문이면 aw brief --init 도 알림" "$(env AW_BRIEF="$IH/b5" "$AW" brief --init)" "생각 빼내기"

# 예상 소요 시간 읽기
"$AW" run -n eta-text -- sh -c 'echo "예상 소요: 약 15분"; echo "일하는 중"; sleep 6; true' >/dev/null 2>&1
cl='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"예상 소요: 약 10~20분\n시작합니다."}]}}'
"$AW" run -n eta-claude -- sh -c 'printf "%s\n" "$1"; sleep 6; true' sh "$cl" >/dev/null 2>&1
ag='{"event":"step_update","step_update":{"state":"ACTIVE","step_type":"agent_response","text_delta":"예상 소"}}
{"event":"step_update","step_update":{"state":"ACTIVE","step_type":"agent_response","text_delta":"요: 약 3"}}
{"event":"step_update","step_update":{"state":"ACTIVE","step_type":"agent_response","text_delta":"0분\n"}}'
"$AW" run -n eta-agy -- sh -c 'printf "%s\n" "$1"; sleep 6; true' sh "$ag" >/dev/null 2>&1
kc='{"type":"sessionUpdate","data":{"sessionId":"K1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"예상 소"}}}}
{"type":"sessionUpdate","data":{"sessionId":"K1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"요: 약 2"}}}}
{"type":"sessionUpdate","data":{"sessionId":"K1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"5분\\n"}}}}'
"$AW" run -n eta-kiro -- sh -c 'printf "%s\n" "$1"; sleep 6; true' sh "$kc" >/dev/null 2>&1
us='{"type":"user","message":{"role":"user","content":"예상 소요: 약 5분 이라고 적으세요"}}'
"$AW" run -n eta-user -- sh -c 'printf "%s\n" "$1"; sleep 6; true' sh "$us" >/dev/null 2>&1
"$AW" run -n eta-over -- sh -c 'echo "예상 소요: 약 1분"; sleep 6; true' >/dev/null 2>&1
sleep 1
has "텍스트 출력의 예상 소요" "$("$AW" peek eta-text)" "예상 소요   : 약 15분"
has "경과와 견줌" "$("$AW" peek eta-text)" "지남)"
has "claude 말의 범위" "$("$AW" peek eta-claude)" "약 10~20분"
has "agy 의 조각난 답을 이어 붙여 읽음" "$("$AW" peek eta-agy)" "약 30분"
has "kiro-cli 의 조각난 답을 이어 붙여 읽음" "$("$AW" peek eta-kiro)" "약 25분"
hasnt "프롬프트(사용자 말)의 예시는 답으로 읽지 않음" "$("$AW" peek eta-user)" "예상 소요   :"
# 시작 시각을 3분 전으로 돌려 예상(1분)을 넘긴 것처럼
m="$AW_HOME/workers/eta-over/meta"
sed "s/^started=.*/started=$(( $(date +%s) - 180 ))/" "$m" > "$m.new" && mv "$m.new" "$m"
has "예상보다 오래 걸리면 알림" "$("$AW" peek eta-over)" "예상보다 2m"
"$AW" wait eta-text eta-claude eta-agy eta-kiro eta-user eta-over --timeout 20 >/dev/null 2>&1
has "끝난 워커는 실제 걸린 시간과 견줌" "$("$AW" peek eta-text)" "(실제 "
"$AW" clean >/dev/null 2>&1

head_ "21. 에이전트 고르기 (aw pick, 실험용)"
# 가짜 curl: 인자·표준 입력(설정)·본문을 남기고 정해 둔 응답을 돌려줍니다. 가짜 에이전트는 인자를 찍습니다.
# PATH 를 좁혀 이 컴퓨터에 깔린 진짜 에이전트가 후보에 끼지 않게 합니다.
PK="$TMPROOT/pick-t"; mkdir -p "$PK/bin" "$PK/stub" "$PK/nogit"
cat > "$PK/bin/curl" <<'STUB'
#!/bin/sh
d=$PICK_STUB
printf '%s\n' "$@" > "$d/args"
cat > "$d/config"
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --data-binary) cp "${2#@}" "$d/body"; shift 2 ;;
    *) shift ;;
  esac
done
code=$(cat "$d/code" 2>/dev/null || echo 200)
if [ "$code" = 000 ]; then echo "curl: (7) Failed to connect to api.typesafe.ai" >&2; printf 000; exit 7; fi
cat "$d/resp" > "$out"
printf '%s' "$code"
STUB
for a in claude codex; do printf '#!/bin/sh\nprintf "%%s\\n" "$0" "$@"\n' > "$PK/bin/$a"; done
chmod +x "$PK/bin/"*
export PICK_STUB="$PK/stub"
PKPATH="$PK/bin:/usr/bin:/bin"
awp() { PATH="$PKPATH" "$AW" "$@"; }
resp() { # <고른 것> <확신>
  printf '{"model":"jev-1.13.0","answers":{"agent":{"type":"choice","choice":"%s","probabilities":{"claude":0.1,"codex":0.9},"confidence":%s}},"usage":{"input_tokens":300,"output_tokens":30}}\n' "$1" "$2" > "$PK/stub/resp"
}
resp codex 0.8

out=$(awp pick)
has "꺼져 있으면 상태에 켜는 법" "$out" "aw pick on"
out=$(awp pick -- 리뷰해줘 2>&1); code=$?
check "꺼져 있으면 띄우지 않음 (코드 1)" 1 "$code"
has "꺼져 있다고 알림" "$out" "꺼져 있습니다"

out=$(awp pick on < /dev/null)
if [ -f "$AW_PICK" ]; then ok "aw pick on 이 설명 파일을 만듦"; else ng "aw pick on 이 파일을 안 만듦"; fi
has "권장값에 모델·수준 줄" "$(cat "$AW_PICK")" "  claude-opus-5-5@xhigh "
has "키가 없으면 넣는 법을 알림" "$out" "aw pick key"
out=$(awp pick --dry-run -- 리뷰해줘 2>&1); code=$?
check "키가 없으면 첫 후보로 대신 (코드 0)" 0 "$code"
has "키가 없다고 알림" "$out" "키가 없음"
has "대신 띄운다고 알림" "$out" "고른 에이전트: claude   (Jev 를 못 써서 대신)"
out=$(awp pick --fallback none --dry-run -- 리뷰해줘 2>&1); code=$?
check "--fallback none 이면 멈춤 (코드 1)" 1 "$code"

KEY=tsk_test_0123456789abcdef
out=$(printf '%s\n' "$KEY" | awp pick key)
check "키 파일은 나만 읽기 (600)" 600 "$(stat -c %a "$AW_PICK_KEYFILE" 2>/dev/null || stat -f %Lp "$AW_PICK_KEYFILE")"
hasnt "키를 넣을 때 키 전체를 찍지 않음" "$out" "$KEY"
out=$(awp pick)
has "상태에 가린 키" "$out" "tsk_…cdef"
hasnt "상태에 키 전체가 없음" "$out" "$KEY"
has "설치된 후보는 있음" "$out" "codex     있음"

out=$(awp pick --dry-run -n rv -- 'src/auth 를 "검토"해줘 \ 끝
둘째 줄'); code=$?
check "dry-run 은 코드 0" 0 "$code"
has "고른 에이전트와 확신" "$out" "고른 에이전트: codex   확신 0.80"
has "띄울 명령이 정석 호출" "$out" "aw run -n 'rv' -- codex exec --json 'src/auth"
if [ -d "$AW_HOME/workers/rv" ]; then ng "dry-run 인데 워커가 생김"; else ok "dry-run 은 워커를 안 띄움"; fi
hasnt "키가 curl 의 인자에 없음" "$(cat "$PK/stub/args")" "$KEY"
has "키는 표준 입력의 설정으로" "$(cat "$PK/stub/config")" "Bearer $KEY"
has "주소는 systemone" "$(cat "$PK/stub/args")" "https://api.typesafe.ai/v1/systemone"
body=$(cat "$PK/stub/body")
has "본문에 Choice 질문" "$body" '"type":"choice"'
has "본문의 작업은 이스케이프됨" "$body" 'src/auth 를 \"검토\"해줘 \\ 끝\n둘째 줄'
has "설치된 claude 는 후보" "$body" '"claude":"Claude Code'
if ! PATH=/usr/bin:/bin command -v devin >/dev/null 2>&1; then
  hasnt "없는 devin 은 후보에서 빠짐" "$body" '"devin"'
fi
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$PK/stub/body" 2>/dev/null; then ok "본문이 올바른 JSON"; else ng "본문이 JSON 이 아님"; fi
  long=$(python3 -c 'print("가나다 \"q\" \\ " * 3000)')
  awp pick --dry-run -- "$long" >/dev/null 2>&1
  n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1], encoding="utf-8"))["state"]["task"].encode()))' "$PK/stub/body" 2>/dev/null)
  if [ -n "$n" ] && [ "$n" -le 12000 ]; then ok "긴 작업은 앞 12KB 만, 글자가 깨지지 않게 ($n 바이트)"; else ng "긴 작업 자르기 ($n)"; fi
fi
env TYPESAFE_API_KEY=envkey_987 PATH="$PKPATH" "$AW" pick --dry-run -- x >/dev/null 2>&1
has "TYPESAFE_API_KEY 가 파일보다 먼저" "$(cat "$PK/stub/config")" "Bearer envkey_987"
env TYPESAFE_API_KEY=envkey_987 PATH="$PKPATH" "$AW" pick --key argkey_654 --dry-run -- x >/dev/null 2>&1
has "--key 가 환경변수보다 먼저" "$(cat "$PK/stub/config")" "Bearer argkey_654"
hasnt "--key 도 curl 의 인자에는 안 실림" "$(cat "$PK/stub/args")" "argkey_654"
check "--key 는 저장하지 않음" "$KEY" "$(cat "$AW_PICK_KEYFILE")"
out=$(awp pick --fallback none --key 'bad"key' --dry-run -- x 2>&1); code=$?
check "따옴표가 든 키는 Jev 에 안 보냄 (none 이면 코드 1)" 1 "$code"
has "따옴표가 든 키라고 알림" "$out" "쓸 수 없는 글자"
awp pick key tsk_arg_saved_1234567 >/dev/null
check "aw pick key <키> 로 저장" tsk_arg_saved_1234567 "$(cat "$AW_PICK_KEYFILE")"
printf '%s\n' "$KEY" | awp pick key >/dev/null

# 실제로 띄움: git 저장소 밖이면 codex 에 --skip-git-repo-check
out=$(awp pick -n pk-run -d "$PK/nogit" -- 로그인 버그 고쳐줘); code=$?
check "띄우면 코드 0" 0 "$code"
awp wait pk-run --timeout 10 >/dev/null 2>&1
check "고른 에이전트의 정석 호출로 돎" "$(printf '%s\n' "$PK/bin/codex" exec --json --skip-git-repo-check '로그인 버그 고쳐줘')" "$(awp result pk-run)"
check "meta 에 고른 에이전트" codex "$(sed -n 's/^picked=//p' "$AW_HOME/workers/pk-run/meta")"
has "aw status 에 보임" "$(awp status pk-run)" "codex 를 고름 (확신 0.80)"
hasnt "워커 기록에 키가 없음" "$(cat "$AW_HOME/workers/pk-run/"* 2>/dev/null)" "$KEY"
if ls -a "$AW_HOME" | grep -q '^\.pick\.'; then ng "임시 파일이 남음"; else ok "임시 파일을 치움"; fi

printf '큰 작업\n' > "$PK/task.md"
out=$(cd "$PK" && PATH="$PKPATH" "$AW" pick --dry-run -f task.md)
has "-f 면 에이전트에도 파일로 (codex 는 -)" "$out" "-f '$PK/task.md' -- codex exec --json --skip-git-repo-check -"

resp codex 0.3
out=$(awp pick -n pk-low -- 뭔가 2>&1); code=$?
check "확신이 하한보다 낮으면 코드 3" 3 "$code"
has "확신이 낮다고 알림" "$out" "확신이 낮아"
if [ -d "$AW_HOME/workers/pk-low" ]; then ng "확신이 낮은데 띄움"; else ok "확신이 낮으면 안 띄움"; fi
out=$(awp pick --min-confidence 0 --dry-run -- 뭔가 2>&1); code=$?
check "--min-confidence 0 이면 1등을 씀" 0 "$code"
out=$(awp pick --min-confidence 2 -- 뭔가 2>&1); code=$?
check "--min-confidence 가 1 을 넘으면 코드 1" 1 "$code"

resp gpt 0.9
out=$(awp pick --dry-run -- 뭔가 2>&1); code=$?
check "후보에 없는 답이면 첫 후보로 대신 (코드 0)" 0 "$code"
has "답을 못 읽었다고 알림" "$out" "답을 읽지 못함"
resp codex 0.8
echo 401 > "$PK/stub/code"
out=$(awp pick --fallback none --dry-run -- 뭔가 2>&1); code=$?
check "401 이고 --fallback none 이면 코드 1" 1 "$code"
has "401 은 키를 확인하라고" "$out" "aw pick key"
# Jev 가 안 될 때 (예산, 서버, 네트워크): 대신 띄울 에이전트로
echo 402 > "$PK/stub/code"; echo '{"detail":"credit balance is too low"}' > "$PK/stub/resp"
out=$(awp pick --dry-run -- 뭔가 2>&1); code=$?
check "402(예산)면 대신 띄움 (코드 0)" 0 "$code"
has "402 의 이유를 알림" "$out" "credit balance is too low"
has "기본은 설명 파일의 첫 후보" "$out" "claude -p --output-format stream-json --verbose '뭔가'"
echo 503 > "$PK/stub/code"
out=$(env AW_PICK_FALLBACK=codex PATH="$PKPATH" "$AW" pick --dry-run -- 뭔가 2>&1); code=$?
check "5xx 면 AW_PICK_FALLBACK 으로 (코드 0)" 0 "$code"
has "AW_PICK_FALLBACK 의 에이전트" "$out" "고른 에이전트: codex   (Jev 를 못 써서 대신)"
echo 000 > "$PK/stub/code"
out=$(awp pick --fallback codex --dry-run -- 뭔가 2>&1); code=$?
check "연결 실패면 --fallback 으로 (코드 0)" 0 "$code"
has "연결 실패 이유" "$out" "닿지 못함"
out=$(awp pick --fallback devin --dry-run -- 뭔가 2>&1); code=$?
check "대신 띄울 에이전트가 없으면 코드 1" 1 "$code"
out=$(awp pick -n pk-jevdown -d "$PK/nogit" -- 뭔가 2>/dev/null); code=$?
check "Jev 가 안 돼도 실제로 띄움" 0 "$code"
has "meta 에 Jev 오류" "$(cat "$AW_HOME/workers/pk-jevdown/meta")" "pick_jev_error=닿지 못함"
has "aw status 에 보임" "$(awp status pk-jevdown)" "Jev 를 못 써서 대신 띄움"
awp wait pk-jevdown --timeout 10 >/dev/null 2>&1
rm -f "$PK/stub/code"; resp codex 0.8

# 모델과 추론 수준: 들여 쓴 줄이 그 에이전트의 모델. 한 요청에 에이전트와 모델 질문을 같이 보냄
cp "$AW_PICK" "$PK/pick.agents-only"
cat > "$AW_PICK" <<'P'
# 시험용
claude Claude Code.
  claude-sonnet-5@medium Simple work.
  claude-opus-5-5@xhigh Ordinary work.
codex Codex CLI.
  gpt-5.6-luna@medium Simple work.
  gpt-5.6-sol@xhigh Hard work.
P
printf '%s\n' '{"model":"jev-1.13.0","answers":{"agent":{"type":"choice","choice":"codex","probabilities":{"claude":0.1,"codex":0.9},"confidence":0.8},"model_claude":{"type":"choice","choice":"claude-opus-5-5@xhigh","probabilities":{"claude-sonnet-5@medium":0.2,"claude-opus-5-5@xhigh":0.8},"confidence":0.6},"model_codex":{"type":"choice","probabilities":{"gpt-5.6-luna@medium":0.05,"gpt-5.6-sol@xhigh":0.95},"choice":"gpt-5.6-sol@xhigh","confidence":0.9}},"usage":{"input_tokens":400,"output_tokens":60}}' > "$PK/stub/resp"
out=$(awp pick --dry-run -d "$PK/nogit" -- '보안 검토'); code=$?
check "모델까지 고르면 코드 0" 0 "$code"
has "고른 모델과 확신" "$out" "고른 모델    : gpt-5.6-sol@xhigh   확신 0.90"
has "codex 는 --model 과 -c model_reasoning_effort" "$out" "codex exec --json --skip-git-repo-check --model 'gpt-5.6-sol' -c 'model_reasoning_effort=xhigh' '보안 검토'"
body=$(cat "$PK/stub/body")
has "본문에 에이전트 질문" "$body" '"agent":{"type":"choice"'
has "본문에 후보마다 모델 질문" "$body" '"model_claude":{"type":"choice"'
has "모델 선택지는 모델@수준" "$body" '"gpt-5.6-sol@xhigh":"Hard work."'
hasnt "에이전트 선택지에 모델 줄이 섞이지 않음" "$(printf '%s' "$body" | sed 's/"model_claude".*//')" 'claude-sonnet-5@medium'
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$PK/stub/body" 2>/dev/null; then ok "모델 질문이 든 본문도 올바른 JSON"; else ng "모델 질문이 든 본문이 JSON 이 아님"; fi
fi
out=$(awp pick -n pk-model -d "$PK/nogit" -- '보안 검토'); code=$?
awp wait pk-model --timeout 10 >/dev/null 2>&1
has "모델 옵션이 실제 명령에" "$(awp result pk-model)" "model_reasoning_effort=xhigh"
check "meta 에 고른 모델" "gpt-5.6-sol@xhigh" "$(sed -n 's/^pick_model=//p' "$AW_HOME/workers/pk-model/meta")"
has "aw status 에 모델" "$(awp status pk-model)" "모델 gpt-5.6-sol@xhigh (확신 0.90)"
# 모델 확신이 낮으면 에이전트는 띄우되 모델은 기본값
sed 's/"choice":"gpt-5.6-sol@xhigh","confidence":0.9/"choice":"gpt-5.6-sol@xhigh","confidence":0.2/' "$PK/stub/resp" > "$PK/stub/r.low" && cp "$PK/stub/r.low" "$PK/stub/resp"
out=$(awp pick --dry-run -d "$PK/nogit" -- '보안 검토'); code=$?
check "모델 확신이 낮아도 코드 0" 0 "$code"
has "모델 확신이 낮으면 기본값" "$out" "고른 모델    : 기본값   (확신 0.20"
hasnt "모델 확신이 낮으면 --model 을 안 붙임" "$out" "--model"
# 에이전트별로 수준을 넘기는 법
for c in "claude:claude-opus-5-5@xhigh:--model 'claude-opus-5-5' --effort 'xhigh'" \
         "agy:gemini-3.8-flash@low:--model 'gemini-3.8-flash' --effort 'low'" \
         "devin:swe-2@max:--model 'swe-2-max'" \
         "kiro-cli:claude-sonnet-5:--model 'claude-sonnet-5' --agent-engine v3" \
         "codex:gpt-5.6-luna:--model 'gpt-5.6-luna'"; do
  ag=${c%%:*}; rest=${c#*:}; spec=${rest%%:*}; want=${rest#*:}
  printf '%s Agent.\n  %s Only model.\n' "$ag" "$spec" > "$AW_PICK"
  [ -x "$PK/bin/$ag" ] || { printf '#!/bin/sh\n' > "$PK/bin/$ag"; chmod +x "$PK/bin/$ag"; }
  out=$(awp pick --dry-run -- 작업 2>&1)
  has "$ag 의 모델 옵션 ($spec)" "$out" "$want"
done
has "모델 줄이 하나면 묻지 않고 씀" "$out" "모델 줄이 하나라 묻지 않았습니다"
printf 'devin Agent.\n  swe-2-max M.\n' > "$AW_PICK"
has "devin 은 모델 옵션을 프롬프트 뒤에" "$(awp pick --dry-run -- 작업 2>&1)" "devin -p '작업' --model 'swe-2-max'"
rm -f "$PK/bin/agy" "$PK/bin/devin" "$PK/bin/kiro-cli"

# 모델이 거부되면(없는 모델 등) 워커가 모델 옵션 없이 한 번 더 돎. 지시문과 기본 옵션은 두 번째에도 붙음
cp "$PK/bin/codex" "$PK/codex.orig"
cat > "$PK/bin/codex" <<'F'
#!/bin/sh
case " $* " in *" bogus-1 "*) echo "Error: Unknown model: 'bogus-1'" >&2; exit 1 ;; esac
printf '%s\n' "$0" "$@"
F
chmod +x "$PK/bin/codex"
printf 'codex Codex.\n  bogus-1@high Only.\n' > "$AW_PICK"
printf 'codex --sandbox workspace-write\ncodex --model good-default\n' > "$PK/defaults"
printf '지시문 한 줄.\n' > "$PK/brief"
env AW_DEFAULTS="$PK/defaults" AW_BRIEF="$PK/brief" PATH="$PKPATH" "$AW" pick -n pk-fb -d "$PK/nogit" -- '작업 해줘' >/dev/null 2>&1
awp wait pk-fb --timeout 10 >/dev/null 2>&1; code=$?
check "모델이 거부돼도 다시 돌아 성공" 0 "$code"
out=$(awp result pk-fb)
hasnt "다시 돌 때는 고른 모델을 빼고" "$out" "bogus-1"
has "기본 옵션의 모델이 붙음" "$out" "good-default"
has "기본 옵션의 권한도 붙음" "$out" "workspace-write"
has "지시문도 붙음" "$out" "지시문 한 줄."
has "첫 시도의 오류를 남김" "$(cat "$AW_HOME/workers/pk-fb/err.model" 2>/dev/null)" "Unknown model"
check "meta 에 되돌아간 기록" 1 "$(sed -n 's/^pick_fallback=//p' "$AW_HOME/workers/pk-fb/meta")"
hasnt "cmd.orig 도 되돌아간 명령 (aw resume 이 없는 모델을 다시 안 씀)" "$(cat "$AW_HOME/workers/pk-fb/cmd.orig")" "bogus-1"
has "aw status 에 보임" "$(awp status pk-fb)" "모델이 거부돼"
# 모델과 상관없는 실패는 다시 돌리지 않음
cat > "$PK/bin/codex" <<'F'
#!/bin/sh
echo "network down" >&2; exit 2
F
env AW_DEFAULTS="$PK/defaults" PATH="$PKPATH" "$AW" pick -n pk-nofb -d "$PK/nogit" -- '작업' >/dev/null 2>&1
awp wait pk-nofb --timeout 10 >/dev/null 2>&1
check "모델과 상관없는 실패는 그대로 (코드 2)" 2 "$(cat "$AW_HOME/workers/pk-nofb/exit")"
if [ -f "$AW_HOME/workers/pk-nofb/out.model" ]; then ng "모델 탓이 아닌데 다시 돌림"; else ok "모델 탓이 아니면 다시 안 돌림"; fi
# 모델을 안 골랐으면 되돌아갈 스크립트도 없음
if [ -f "$AW_HOME/workers/pk-run/fallback.sh" ]; then ng "모델이 없는데 fallback.sh 를 만듦"; else ok "모델을 안 골랐으면 fallback.sh 없음"; fi
mv "$PK/codex.orig" "$PK/bin/codex"
cp "$PK/pick.agents-only" "$AW_PICK"
resp codex 0.8

# 빼기: --without 과 AW_PICK_WITHOUT. 에이전트, 에이전트:모델(수준 상관없이), 에이전트:모델@수준
printf 'claude Claude.\n  claude-sonnet-5@low S.\n  claude-opus-5-5@xhigh O.\ncodex Codex.\n  gpt-6-luna@medium L.\n  gpt-6-astra@xhigh A.\n' > "$PK/pick.w"
printf '%s\n' '{"model":"jev-1.13.0","answers":{"agent":{"type":"choice","choice":"claude","probabilities":{"claude":0.9,"codex":0.1},"confidence":0.8}},"usage":{"input_tokens":1,"output_tokens":1}}' > "$PK/stub/resp"
awpw() { env AW_PICK="$PK/pick.w" PATH="$PKPATH" "$AW" "$@"; }
awpw pick --without codex:gpt-6-astra --dry-run -- 작업 >/dev/null 2>&1
body=$(cat "$PK/stub/body")
hasnt "에이전트:모델 이면 그 모델 줄을 Jev 에 안 보냄" "$body" '"gpt-6-astra@xhigh"'
has "다른 에이전트의 모델 줄은 그대로" "$body" '"claude-sonnet-5@low"'
printf '%s\n' '{"model":"jev-1.13.0","answers":{"agent":{"type":"choice","choice":"codex","probabilities":{"claude":0.1,"codex":0.9},"confidence":0.8}},"usage":{"input_tokens":1,"output_tokens":1}}' > "$PK/stub/resp"
has "남은 한 줄은 묻지 않고 씀" "$(awpw pick --without codex:gpt-6-astra --dry-run -- 작업 2>&1)" "고른 모델    : gpt-6-luna@medium   (모델 줄이 하나라"
printf '%s\n' '{"model":"jev-1.13.0","answers":{"agent":{"type":"choice","choice":"claude","probabilities":{"claude":0.9,"codex":0.1},"confidence":0.8}},"usage":{"input_tokens":1,"output_tokens":1}}' > "$PK/stub/resp"
awpw pick --without claude:claude-opus-5-5@xhigh --dry-run -- 작업 >/dev/null 2>&1
hasnt "에이전트:모델@수준 이면 그 줄 하나를 뺌" "$(cat "$PK/stub/body")" '"claude-opus-5-5@xhigh"'
rm -f "$PK/stub/args"
out=$(awpw pick --without codex --dry-run -- 작업 2>&1)
has "에이전트를 빼면 남은 후보만" "$out" "고른 에이전트: claude   (후보가 이것 하나라 묻지 않았습니다)"
has "뺀 것을 알림" "$out" "(뺀 것: codex"
out=$(env AW_PICK_WITHOUT=codex AW_PICK="$PK/pick.w" PATH="$PKPATH" "$AW" pick --dry-run -- 작업 2>&1)
has "AW_PICK_WITHOUT 으로도 뺌" "$out" "고른 에이전트: claude   (후보가 이것 하나라"
has "상태에 뺀 것" "$(env AW_PICK_WITHOUT=codex:gpt-6-luna AW_PICK="$PK/pick.w" PATH="$PKPATH" "$AW" pick)" "(뺌) L."
out=$(awpw pick --without claude,codex --dry-run -- 작업 2>&1); code=$?
check "다 빼면 코드 1" 1 "$code"
has "다 뺐다고 알림" "$out" "뺀 것: claude codex"
out=$(awpw pick --without codx --without codex:nope --dry-run -- 작업 2>&1)
has "모르는 에이전트를 빼려 하면 알림" "$out" "모르는 에이전트라 뺄 수 없습니다: codx"
has "없는 모델 줄을 빼려 하면 알림" "$out" "그 모델 줄이 없습니다: codex:nope"
echo 503 > "$PK/stub/code"
out=$(awpw pick --without claude --dry-run -- 작업 2>&1)
has "Jev 를 못 쓸 때 대신 띄우는 것도 뺀 것을 건너뜀" "$out" "고른 에이전트: codex   (Jev 를 못 써서 대신)"
rm -f "$PK/stub/code"
awpw pick -n pk-without --without codex:gpt-6-astra -d "$PK/nogit" -- 작업 >/dev/null 2>&1
check "meta 에 뺀 것" "codex:gpt-6-astra" "$(sed -n 's/^pick_without=//p' "$AW_HOME/workers/pk-without/meta")"
awp wait pk-without --timeout 10 >/dev/null 2>&1
resp codex 0.8

# 후보가 하나면 묻지 않음
rm -f "$PK/stub/args"
grep -v '^[[:space:]]' "$AW_PICK" | sed 's/^codex /#codex /' > "$AW_PICK.new" && mv "$AW_PICK.new" "$AW_PICK"
out=$(awp pick --dry-run -- 뭔가 2>&1)
has "후보가 하나면 그걸 씀" "$out" "claude -p --output-format stream-json --verbose '뭔가'"
if [ -f "$PK/stub/args" ]; then ng "후보가 하나인데 Jev 에 물음"; else ok "후보가 하나면 Jev 에 묻지 않음"; fi

# 끄고 켜기: 고친 설명과 키는 남음
awp pick off >/dev/null
if [ -f "$AW_PICK.off" ] && [ ! -f "$AW_PICK" ]; then ok "aw pick off 는 설명을 .off 로 옮김"; else ng "aw pick off"; fi
out=$(awp pick -- 뭔가 2>&1); code=$?
check "끄면 다시 코드 1" 1 "$code"
if [ -f "$AW_PICK_KEYFILE" ]; then ok "꺼도 키는 남음"; else ng "끄면서 키를 지움"; fi
awp pick on < /dev/null >/dev/null
has "다시 켜면 고친 설명이 돌아옴" "$(cat "$AW_PICK")" "#codex "
awp pick on --force < /dev/null >/dev/null
hasnt "--force 면 권장값으로" "$(cat "$AW_PICK")" "#codex "
rm -f "$AW_PICK" "$AW_PICK_KEYFILE"
out=$(awp pick on --key tsk_on_key_7654321 < /dev/null)
if [ -f "$AW_PICK" ]; then ok "aw pick on --key 가 켬"; else ng "aw pick on --key 가 안 켬"; fi
check "aw pick on --key 가 키를 저장" tsk_on_key_7654321 "$(cat "$AW_PICK_KEYFILE" 2>/dev/null)"
hasnt "aw pick on --key 가 키 전체를 찍지 않음" "$out" tsk_on_key_7654321
awp clean >/dev/null 2>&1

head_ "22. 모델 목록 (aw models)"
# 가짜 CLI 가 실제 형식 그대로 목록을 내고, 에이전트로 불리면 인자를 찍습니다. 목록은 $MF 의 파일이라 바꿀 수 있습니다.
MF="$TMPROOT/models-t"; MB="$MF/bin"; mkdir -p "$MB" "$MF/codex"
export MF
for a in agy devin kiro-cli claude; do
  cat > "$MB/$a" <<'F'
#!/bin/sh
n=${0##*/}
case "$n:$*" in
  agy:models | "devin:models list" | "kiro-cli:chat --list-models")
    echo called >> "$MF/$n.calls"
    [ -f "$MF/$n.fail" ] && exit 1
    cat "$MF/$n.list"; exit 0 ;;
esac
printf '%s\n' "$0" "$@"
F
  chmod +x "$MB/$a"
done
printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\ngemini-3.8-flash-low\tGemini 3.8 Flash (Low)\ngemini-3.1-pro-high\tGemini 3.1 Pro (High)\n' > "$MF/agy.list"
cat > "$MF/devin.list" <<'L'
Available models (2 families)

SWE-2 (swe-2)
  aliases: swe
  swe-2-high                  SWE-2 High  [262K context, Free]
  swe-2-max                   SWE-2 Max  [262K context, Free]

Claude Opus 5.5 (claude-opus-5.5)
  claude-opus-5-5-high        Claude Opus 5.5 High  [1M context, $4 / 1M Input]

Pass a family slug, alias, or model UID to `--model` (e.g. `--model opus`)
or switch models in a session with `/model <name>`.
L
cat > "$MF/kiro-cli.list" <<'L'
Available models (* = default):

* auto                 1.00x credits      Models chosen by task for optimal usage
  claude-opus-5.5      2.00x credits      Experimental preview of Claude Opus 5.5
  claude-sonnet-5      1.30x credits      Claude Sonnet 5 model with 1M context window
L
cat > "$MF/codex/models_cache.json" <<'L'
{
  "fetched_at": "2026-09-29T00:00:00Z",
  "models": [
    {
      "slug": "gpt-6-astra",
      "visibility": "list"
    },
    {
      "slug": "gpt-6-luna",
      "visibility": "list"
    }
  ]
}
L
printf 'model = "gpt-6-astra"\nmodel_reasoning_effort = "medium"\n[features]\nmodel = "not-this"\n' > "$MF/codex/config.toml"
awm() { env PATH="$MB:/usr/bin:/bin" CODEX_HOME="$MF/codex" "$AW" "$@"; }

out=$(awm models)
has "요약에 codex 모델 수와 기본 (config.toml 맨 위의 model)" "$out" "codex     2     gpt-6-astra"
has "요약에 kiro-cli 의 기본(*)" "$out" "kiro-cli  3     auto"
has "claude 는 목록 명령이 없음" "$out" "목록 명령이 없어 확인하지 않음"
check "devin: 계열·별칭·ID 를 다 모음" "$(printf '%s\n' swe-2 swe swe-2-high swe-2-max claude-opus-5.5 claude-opus-5-5-high)" "$(awm models devin)"
check "agy: 모델 이름만" "$(printf '%s\n' gemini-3.8-flash-high gemini-3.8-flash-low gemini-3.1-pro-high)" "$(awm models agy)"
has "kiro-cli: 기본은 앞에 *" "$(awm models kiro-cli)" "* auto"
if awm models claude >/dev/null 2>&1; then ng "claude 목록을 안다고 함"; else ok "claude 목록은 모른다고 (코드 1)"; fi

# 기본 옵션의 모델이 목록에 있으면 붙이고, 없으면 그 줄을 빼고 CLI 기본으로
printf 'agy --model gemini-3.8-flash --effort high\ndevin --model swe\nkiro-cli --trust-all-tools\nkiro-cli --model gone-model\nclaude --model whatever-name\ncodex --model gpt-6-luna\n' > "$MF/defaults"
awd() { env PATH="$MB:/usr/bin:/bin" CODEX_HOME="$MF/codex" AW_DEFAULTS="$MF/defaults" "$AW" "$@"; }
awd run -n md-agy -- agy -p=작업 >/dev/null 2>&1
awd run -n md-devin -- devin -p 작업 >/dev/null 2>&1
out=$(awd run -n md-kiro -- kiro-cli chat 작업 2>&1)
awd run -n md-claude -- claude -p 작업 >/dev/null 2>&1
printf '#!/bin/sh\nprintf "%%s\\n" "$0" "$@"\n' > "$MB/codex"; chmod +x "$MB/codex"
awd run -n md-codex -- codex exec 작업 >/dev/null 2>&1
awm wait md-agy md-devin md-kiro md-claude md-codex --timeout 10 >/dev/null 2>&1
has "agy: 수준을 뗀 이름(gemini-3.8-flash)도 목록의 -high 와 맞음" "$(awm result md-agy)" "gemini-3.8-flash"
has "devin: 별칭(swe)도 목록에 있음" "$(awm result md-devin)" "swe"
hasnt "kiro-cli: 목록에 없는 모델 줄은 뺌" "$(awm result md-kiro)" "gone-model"
has "kiro-cli: 다른 줄(권한)은 그대로" "$(awm result md-kiro)" "--trust-all-tools"
has "kiro-cli: 뺀 줄 전체를 알림" "$out" "기본 옵션 '--model gone-model' 는 뺐습니다: 모델이 kiro-cli 의 모델 목록에 없음"
check "meta 에 뺀 줄" "--model gone-model" "$(sed -n 's/^default_model_dropped=//p' "$AW_HOME/workers/md-kiro/meta")"
has "claude: 목록을 모르면 그대로" "$(awm result md-claude)" "whatever-name"
has "codex: models_cache.json 의 모델이면 그대로" "$(awm result md-codex)" "gpt-6-luna"

# 캐시에 없는 모델은 한 번 새로 물어본 뒤 정함 (목록이 바뀌었을 수 있음)
printf 'kiro-cli --model claude-new-6\n' > "$MF/defaults"
: > "$MF/kiro-cli.calls"
printf '  claude-new-6         1.00x credits      new\n' >> "$MF/kiro-cli.list"
awd run -n md-kiro2 -- kiro-cli chat 작업 >/dev/null 2>&1
awm wait md-kiro2 --timeout 10 >/dev/null 2>&1
has "캐시에 없던 새 모델은 새로 물어 붙임" "$(awm result md-kiro2)" "claude-new-6"
check "그때 목록을 한 번 물어봄" 1 "$(grep -c called "$MF/kiro-cli.calls")"
: > "$MF/kiro-cli.calls"
awd run -n md-kiro3 -- kiro-cli chat 작업 >/dev/null 2>&1
check "캐시에 있으면 다시 묻지 않음" 0 "$(grep -c called "$MF/kiro-cli.calls")"
# 목록을 새로 받지 못하면(조회 실패) 낡은 캐시로 빼지 않고 그대로
printf 'kiro-cli --model not-in-cache\n' > "$MF/defaults"; touch "$MF/kiro-cli.fail"
awd run -n md-kiro4 -- kiro-cli chat 작업 >/dev/null 2>&1
awm wait md-kiro3 md-kiro4 --timeout 10 >/dev/null 2>&1
has "조회에 실패하면 정한 기본을 그대로" "$(awm result md-kiro4)" "not-in-cache"
rm -f "$MF/kiro-cli.fail"
awm models --refresh kiro-cli >/dev/null 2>&1
has "--refresh 로 다시 받음" "$(awm models kiro-cli)" "claude-new-6"

# aw pick: 목록에 없는 모델 줄은 고르지 않음
printf 'codex Codex.\n  gpt-6-luna@medium Simple.\n  gpt-5.6-terra@high Gone.\n' > "$MF/pick"
out=$(env PATH="$MB:$PK/bin:/usr/bin:/bin" CODEX_HOME="$MF/codex" AW_PICK="$MF/pick" PICK_STUB="$PK/stub" "$AW" pick --dry-run -- 리뷰 2>&1)
has "pick: 목록에 없는 줄은 뺐다고 알림" "$out" "고르지 않은 줄: gpt-5.6-terra@high"
has "pick: 남은 한 줄은 묻지 않고 씀" "$out" "고른 모델    : gpt-6-luna@medium   (모델 줄이 하나라 묻지 않았습니다)"
has "pick 상태: 목록에 없는 줄 표시" "$(env PATH="$MB:$PK/bin:/usr/bin:/bin" CODEX_HOME="$MF/codex" AW_PICK="$MF/pick" "$AW" pick)" "(목록에 없음)"
awm clean >/dev/null 2>&1

head_ "23. 게이트웨이 (aw gateway)"
# 네트워크에 나가지 않습니다. curl 은 정해 둔 모델 목록을 돌려주고, codex·claude 는 받은 인자를 찍습니다.
GW="$TMPROOT/gw"; mkdir -p "$GW/bin" "$GW/stub" "$GW/codex" "$GW/cp"
cat > "$GW/bin/curl" <<'STUB'
#!/bin/sh
d=$GW_STUB
printf '%s\n' "$@" > "$d/args"
cat > "$d/config"
out=''
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
cat "$d/resp" > "$out"
cat "$d/code" 2>/dev/null || printf 200
STUB
cat > "$GW/bin/codex" <<'STUB'
#!/bin/sh
printf '{"type":"thread.started","thread_id":"tid-gw"}\n'
printf '%s\n' "$@"
STUB
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$GW/bin/claude"
chmod +x "$GW/bin/"*
# providers 안의 {"id": 도 있는 실제 모양 그대로 (OpenGateway /v1/models)
pv='"providers":[{"id":"p1","region":"global"}]'
printf '{"object":"list","data":[%s,%s,%s,%s,%s]}\n' \
  "{\"id\":\"x/both\",\"object\":\"model\",\"status\":\"active\",\"endpoints\":[\"chat_completions\",\"messages\",\"responses\"],$pv}" \
  "{\"id\":\"x/resp\",\"object\":\"model\",\"status\":\"active\",\"endpoints\":[\"chat_completions\",\"responses\"],$pv}" \
  "{\"id\":\"x/msg\",\"object\":\"model\",\"status\":\"active\",\"endpoints\":[\"chat_completions\",\"messages\"],$pv}" \
  "{\"id\":\"x/chat\",\"object\":\"model\",\"status\":\"active\",\"endpoints\":[\"chat_completions\"],$pv}" \
  "{\"id\":\"x/old\",\"object\":\"model\",\"status\":\"deprecated\",\"endpoints\":[\"messages\",\"responses\"],$pv}" > "$GW/stub/resp"
printf 'codex --sandbox workspace-write\ncodex --model gpt-x\nclaude --permission-mode bypassPermissions\nclaude --model opus-x\nclaude --effort xhigh\n' > "$GW/defaults"
awg() { env -u OPENGATEWAY_API_KEY PATH="$GW/bin:/usr/bin:/bin" GW_STUB="$GW/stub" CODEX_HOME="$GW/codex" CLAUDE_PROFILE_ROOT="$GW/cp" AW_DEFAULTS="$GW/defaults" "$AW" "$@"; }

has "만든 게이트웨이가 없으면 그렇게 알림" "$(awg gateway)" "만든 게이트웨이가 없습니다"
out=$(awg gateway add opengateway --model x/both 2>&1)
has "add: 알려진 게이트웨이의 주소로 모델 목록을 봄" "$(cat "$GW/stub/args")" "https://apis.opengateway.ai/v1/models"
has "add: codex 프로필을 만듦" "$out" "codex : 만듦"
has "add: claude 프로필을 만듦" "$out" "claude: 만듦"
has "add: 키가 셸에 없으면 알려 줌" "$out" "이 셸에 \$OPENGATEWAY_API_KEY 가 없습니다"
cf="$GW/codex/opengateway.config.toml"; cd_="$GW/cp/opengateway"
check "codex 파일 첫 줄은 aw 표식" "# aw gateway: opengateway" "$(head -1 "$cf" | cut -c1-25)"
has "codex 파일에 게이트웨이 정의 (/v1)" "$(cat "$cf")" 'base_url = "https://apis.opengateway.ai/v1"'
has "codex 파일에 모델" "$(cat "$cf")" 'model = "x/both"'
has "codex 파일에서 앱 도구를 끔" "$(cat "$cf")" "apps = false"
has "claude 프로필에 주소 (/v1 없이)" "$(cat "$cd_/settings.json")" '"ANTHROPIC_BASE_URL": "https://apis.opengateway.ai"'
has "claude 프로필은 키를 환경변수에서 읽음" "$(cat "$cd_/settings.json")" 'printf %s \"$OPENGATEWAY_API_KEY\"'
if [ -f "$cd_/.aw-gateway" ]; then ok "claude 프로필에 aw 표식"; else ng "claude 프로필에 표식이 없음"; fi
out=$(env OPENGATEWAY_API_KEY=sekrit PATH="$GW/bin:/usr/bin:/bin" GW_STUB="$GW/stub" CODEX_HOME="$GW/codex" CLAUDE_PROFILE_ROOT="$GW/cp" "$AW" gateway add opengateway --model x/both 2>&1)
hasnt "키는 curl 의 인자에 없음" "$(cat "$GW/stub/args")" "sekrit"
hasnt "키 값은 만든 파일에 없음" "$(cat "$cf" "$cd_/settings.json" "$cd_/.aw-gateway")" "sekrit"
has "키는 표준 입력의 설정으로" "$(cat "$GW/stub/config")" "Bearer sekrit"
has "다시 add 하면 바꿈" "$out" "codex : 바꿈"
has "상태: 키가 있음" "$(env OPENGATEWAY_API_KEY=k PATH="$GW/bin:/usr/bin:/bin" CODEX_HOME="$GW/codex" CLAUDE_PROFILE_ROOT="$GW/cp" "$AW" gateway)" "키 \$OPENGATEWAY_API_KEY: 있음"
has "상태: 키가 없음" "$(awg gateway)" "키 \$OPENGATEWAY_API_KEY: 없음"

out=$(awg gateway models opengateway codex)
has "models codex: Responses 를 지원하는 모델" "$out" "x/resp"
hasnt "models codex: Messages 만 되는 모델은 뺌" "$out" "x/msg"
out=$(awg gateway models opengateway claude)
has "models claude: Messages 를 지원하는 모델" "$out" "x/msg"
hasnt "models claude: chat 전용은 뺌" "$out" "x/chat"
hasnt "providers 의 id 는 모델로 치지 않음" "$(awg gateway models opengateway)" "p1"

# 모델이 Responses 만 되면 claude 쪽은 만들지 않고, 전에 만든 claude 프로필은 지움
out=$(awg gateway add opengateway --model x/resp 2>&1)
has "Responses 만 되는 모델: claude 는 만들지 않음" "$out" "claude: 만들지 않음"
if [ -e "$cd_" ]; then ng "옛 모델의 claude 프로필이 남음"; else ok "옛 모델의 claude 프로필은 지움"; fi
has "codex 는 새 모델로" "$(cat "$cf")" 'model = "x/resp"'
out=$(awg gateway add gw-msg --url https://gw.example/v1/ --key-env GWKEY --model x/msg 2>&1)
if [ -e "$GW/codex/gw-msg.config.toml" ]; then ng "Messages 만 되는 모델인데 codex 를 만듦"; else ok "Messages 만 되는 모델: codex 는 만들지 않음"; fi
has "주소 끝의 /v1/ 은 떼고 씀" "$(cat "$GW/cp/gw-msg/settings.json")" '"ANTHROPIC_BASE_URL": "https://gw.example"'
if awg gateway add gw-chat --url https://gw.example --key-env GWKEY --model x/chat >/dev/null 2>&1; then ng "chat 전용 모델을 받아들임"; else ok "codex·claude 둘 다 안 되는 모델은 거절"; fi
if awg gateway add gw-none --url https://gw.example --key-env GWKEY --model x/nope >/dev/null 2>&1; then ng "목록에 없는 모델을 받아들임"; else ok "목록에 없는 모델은 거절"; fi
if [ -e "$GW/codex/gw-chat.config.toml" ] || [ -e "$GW/codex/gw-none.config.toml" ] || [ -e "$GW/cp/gw-none" ]; then ng "거절했는데 파일을 만듦"; else ok "거절하면 아무것도 만들지 않음"; fi
has "deprecated 모델은 알리고 만듦" "$(awg gateway add gw-old --url https://gw.example --key-env GWKEY --model x/old 2>&1)" "deprecated 상태입니다"
if awg gateway add 'bad name' --url https://gw.example --key-env K --model x/both >/dev/null 2>&1; then ng "잘못된 이름을 받아들임"; else ok "잘못된 이름은 거절"; fi
if awg gateway add gw-inj --url https://gw.example --key-env 'K;touch /tmp/aw-gw-inj' --model x/both >/dev/null 2>&1; then ng "잘못된 환경변수 이름을 받아들임"; else ok "잘못된 환경변수 이름은 거절"; fi
printf 500 > "$GW/stub/code"
has "목록을 못 받으면 확인 못 했다고 알리고 만듦" "$(awg gateway add gw-off --url https://gw.example --key-env GWKEY --model whatever 2>&1)" "확인하지 못했습니다"
if [ -f "$GW/codex/gw-off.config.toml" ] && [ -f "$GW/cp/gw-off/settings.json" ]; then ok "그때는 codex·claude 둘 다 만듦"; else ng "목록 없이 만들지 못함"; fi
rm -f "$GW/stub/code"
# aw 가 만들지 않은 같은 이름의 파일은 건드리지 않음
printf 'model = "mine"\n' > "$GW/codex/mine.config.toml"
has "남의 codex 파일은 건너뜀" "$(awg gateway add mine --url https://gw.example --key-env GWKEY --model x/both 2>&1)" "건너뜀"
check "남의 codex 파일은 그대로" 'model = "mine"' "$(cat "$GW/codex/mine.config.toml")"
has "남의 파일은 rm 도 남김" "$(awg gateway rm mine)" "남김"
if [ -f "$GW/codex/mine.config.toml" ] && [ ! -e "$GW/cp/mine" ]; then ok "rm 은 aw 가 만든 것만 지움"; else ng "rm 이 남의 파일을 지웠거나 우리 것을 남김"; fi

# 띄우기: 프로필이 모델을 정하면 기본 옵션의 모델 줄은 빠지고 나머지는 붙음
awg gateway add opengateway --model x/both >/dev/null 2>&1
out=$(awg run -n gw-c -- codex exec --json --profile opengateway 작업 2>&1)
has "codex --profile: 기본 모델을 뺐다고 알림" "$out" "프로필 opengateway 에 모델이 정해져 있음"
awg wait gw-c >/dev/null 2>&1
r=$(awg result gw-c)
hasnt "codex --profile: 기본 모델이 안 붙음" "$r" "gpt-x"
has "codex --profile: 다른 기본 옵션은 붙음" "$r" "workspace-write"
awg run -n gw-m -- codex exec --json -m mine-model 작업 >/dev/null 2>&1; awg wait gw-m >/dev/null 2>&1
hasnt "codex -m 은 --model 과 같은 옵션" "$(awg result gw-m)" "gpt-x"
awg run -n gw-p -- codex exec --json --profile nomodel 작업 >/dev/null 2>&1; awg wait gw-p >/dev/null 2>&1
has "모델을 정하지 않는 프로필이면 기본 모델이 붙음" "$(awg result gw-p)" "gpt-x"
awg run -n gw-l --profile opengateway -- claude -p 작업 >/dev/null 2>&1; awg wait gw-l >/dev/null 2>&1
r=$(awg result gw-l)
hasnt "claude --profile(게이트웨이): 기본 모델이 안 붙음" "$r" "opus-x"
has "claude --profile(게이트웨이): 수준 줄은 붙음" "$r" "xhigh"
awg run -n gw-w --profile work -- claude -p 작업 >/dev/null 2>&1; awg wait gw-w >/dev/null 2>&1
has "모델을 정하지 않는 claude 프로필이면 기본 모델이 붙음" "$(awg result gw-w)" "opus-x"
# 이어하기: codex 의 --profile 은 exec 의 옵션이라 resume 앞에 둠 (뒤에 두면 codex 가 거절)
awg resume gw-c -n gw-c2 -- 다음 >/dev/null 2>&1; awg wait gw-c2 >/dev/null 2>&1
check "codex 이어하기는 --profile 을 resume 앞에" "exec --profile opengateway resume tid-gw" "$(awg result gw-c2 | sed -n '2,6p' | tr '\n' ' ' | sed 's/ $//')"
awg resume gw-c2 -n gw-c3 -- 또 >/dev/null 2>&1; awg wait gw-c3 >/dev/null 2>&1
check "이은 워커를 다시 이어도 같음" "exec --profile opengateway resume tid-gw" "$(awg result gw-c3 | sed -n '2,6p' | tr '\n' ' ' | sed 's/ $//')"
awg rm gw-c gw-c2 gw-c3 gw-m gw-p gw-l gw-w >/dev/null 2>&1

has "rm: 지움" "$(awg gateway rm opengateway)" "지움:"
if [ -e "$cf" ] || [ -e "$cd_" ]; then ng "rm 뒤에 남음"; else ok "rm 이 codex 파일과 claude 프로필을 지움"; fi

# aw uninstall 도 게이트웨이 프로필을 지움
UH="$GW/uhome"; mkdir -p "$UH"
awg gateway add opengateway --model x/both >/dev/null 2>&1
out=$(env -u AW_DEFAULTS -u AW_BRIEF -u AW_PICK -u AW_PICK_KEYFILE -u AW_CONFIG HOME="$UH" XDG_CONFIG_HOME="$UH/.config" \
        AW_HOME="$UH/awhome" AW_PREFIX="$UH/bin" PATH="$GW/bin:/usr/bin:/bin" CODEX_HOME="$GW/codex" CLAUDE_PROFILE_ROOT="$GW/cp" \
        sh "$AW" uninstall --yes 2>&1)
has "uninstall 이 게이트웨이 프로필을 보여 줌" "$out" "== 게이트웨이 프로필"
if [ -e "$cf" ] || [ -e "$cd_" ]; then ng "uninstall 뒤에 게이트웨이 프로필이 남음"; else ok "uninstall 이 게이트웨이 프로필을 지움"; fi
if [ -f "$GW/codex/mine.config.toml" ]; then ok "uninstall 은 남의 codex 파일을 남김"; else ng "uninstall 이 남의 파일을 지움"; fi

printf '\n통과 %d / 실패 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
