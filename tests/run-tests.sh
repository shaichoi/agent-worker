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
for n in agy claude devin myagent; do printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$DSTUB/$n"; chmod +x "$DSTUB/$n"; done
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
check "agy 에 권한 우회가 붙음" "$(printf -- '-p=질문\n--dangerously-skip-permissions')" "$("$AW" result def-agy)"

"$AW" run -n def-claude -- claude -p 질문 >/dev/null 2>&1
"$AW" wait def-claude >/dev/null 2>&1
check "값이 딸린 옵션도 온전히 붙음" "$(printf -- '-p\n질문\n--permission-mode\nbypassPermissions')" "$("$AW" result def-claude)"
# devin 은 승인 우회와 작업 공간 신뢰 검사 끄기를 한 줄에 같이 둡니다.
# -w 가 만드는 worktree 는 실행 시점에 생기는 경로라 미리 신뢰 등록을 할 수 없습니다.
"$AW" run -n def-devin -- devin -p 질문 >/dev/null 2>&1
"$AW" wait def-devin >/dev/null 2>&1
check "devin 에 신뢰 검사 끄기까지 붙음" "$(printf -- '-p\n질문\n--permission-mode\ndangerous\n--respect-workspace-trust\nfalse')" "$("$AW" result def-devin)"
# 줄 단위 판단이라, 그 줄의 첫 옵션을 직접 주면 줄 전체가 빠집니다 (문서화된 함정).
"$AW" run -n def-devin-own -- devin -p 질문 --permission-mode smart >/dev/null 2>&1
"$AW" wait def-devin-own >/dev/null 2>&1
check "첫 옵션을 직접 주면 그 줄이 통째로 빠짐" "$(printf -- '-p\n질문\n--permission-mode\nsmart')" "$("$AW" result def-devin-own)"

"$AW" run -n def-user -- claude -p 질문 --permission-mode acceptEdits >/dev/null 2>&1
"$AW" wait def-user >/dev/null 2>&1
check "사용자 지정이 있으면 덧붙이지 않음" "$(printf -- '-p\n질문\n--permission-mode\nacceptEdits')" "$("$AW" result def-user)"

"$AW" run -n def-off --no-defaults -- agy -p=질문 >/dev/null 2>&1
"$AW" wait def-off >/dev/null 2>&1
check "--no-defaults 로 끌 수 있음" '-p=질문' "$("$AW" result def-off)"

printf 'myagent --yolo --quiet\n' >> "$AW_DEFAULTS"
"$AW" run -n def-custom -- myagent 작업 >/dev/null 2>&1
"$AW" wait def-custom >/dev/null 2>&1
check "사용자가 새 에이전트를 추가할 수 있음" "$(printf '작업\n--yolo\n--quiet')" "$("$AW" result def-custom)"
case "$("$AW" defaults)" in *dangerously-skip-permissions*) ok "aw defaults 가 적용 중인 표를 보여줌" ;; *) ng "aw defaults 출력 이상" ;; esac
case "$(cat "$AW_DEFAULTS")" in *"--respect-workspace-trust false"*) ok "권장값에 devin 신뢰 검사 끄기가 들어 있음" ;; *) ng "권장값에 신뢰 검사 옵션 없음" ;; esac
"$AW" clean --all >/dev/null 2>&1

# 설치 스크립트가 켜 주는지 / --no-defaults 로 건너뛰는지
IH="$TMPROOT/insthome"
rm -rf "$IH"; mkdir -p "$IH"
(cd "$SRC_DIR" && env -u AW_DEFAULTS HOME="$IH" XDG_CONFIG_HOME="$IH/.config" AW_PREFIX="$IH/bin" sh ./install.sh >/dev/null 2>&1)
if [ -f "$IH/.config/agent-worker/defaults" ]; then ok "install.sh 가 기본 옵션을 켜 줌"; else ng "install.sh 가 켜지 않음"; fi
rm -rf "$IH"; mkdir -p "$IH"
(cd "$SRC_DIR" && env -u AW_DEFAULTS HOME="$IH" XDG_CONFIG_HOME="$IH/.config" AW_PREFIX="$IH/bin" sh ./install.sh --no-defaults >/dev/null 2>&1)
if [ -f "$IH/.config/agent-worker/defaults" ]; then ng "--no-defaults 인데 켜 버림"; else ok "install.sh --no-defaults 는 켜지 않음"; fi
unset AW_DEFAULTS

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
# 파일로 프롬프트 넣는 법은 에이전트마다 다릅니다. 넷 다 적혀 있어야 합니다.
lim=$("$AW" help limits)
for want in claude agy codex devin; do
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
unset AW_DEFAULTS

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
  (cd "$SRC_DIR" && env -u AW_DEFAULTS HOME="$IH" XDG_CONFIG_HOME="$IH/.config" AW_PREFIX="$IH/bin" \
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
(env HOME="$IH" AW_PREFIX="$IH/bin" AW_HOME="$IH/awhome" PATH="/usr/bin:/bin" sh "$SRC_DIR/uninstall.sh" >/dev/null 2>&1)
if [ -e "$IH/.claude/skills/agent-worker" ] || [ -e "$IH/.agents/skills/agent-worker" ]; then
  ng "uninstall.sh 가 우리 스킬을 남김"
else ok "uninstall.sh 가 우리 스킬을 지움"; fi
if [ -f "$IH/.gemini/config/skills/agent-worker/SKILL.md" ]; then ok "uninstall.sh 는 남의 스킬을 남김"; else ng "uninstall.sh 가 남의 스킬을 지움"; fi

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
    (cd "$IH/empty" && env -u AW_DEFAULTS HOME="$IH" XDG_CONFIG_HOME="$IH/.config" AW_PREFIX="$IH/bin" \
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
    printf 'y\n\n' | script -qec "cd '$IH/empty' && env -u AW_DEFAULTS HOME='$IH' XDG_CONFIG_HOME='$IH/.config' AW_PREFIX='$IH/bin' PATH='$IH/fakebin:/usr/bin:/bin' AW_RAW_URL='file://$AW' sh < '$SRC_DIR/install.sh'" /dev/null >/dev/null 2>&1
    if [ -f "$IH/.claude/skills/agent-worker/SKILL.md" ]; then ok "파이프 설치에서 y 로 고른 곳엔 넣음"; else ng "y 라 했는데 안 넣음"; fi
    if [ -e "$IH/.gemini" ]; then ng "Enter(기본 아니오)인데 넣음"; else ok "그냥 Enter 면 넣지 않음 (기본 아니오)"; fi
  fi
else
  echo "  (curl 없음: 파이프 설치 시험 생략)"
fi

head_ "17. 설치 점검 (aw setup)"
fresh; fake codex
out=$(env HOME="$IH" PATH="$IH/fakebin:/usr/bin:/bin" AW_DEFAULTS="$IH/defaults" "$AW" setup < /dev/null 2>&1)
for want in "[1/4] 권한 옵션" "[2/4] 에이전트 CLI" "[3/4] 에이전트 스킬" "[4/4] PATH" "아무것도 바꾸지 않습니다"; do
  case "$out" in *"$want"*) ok "점검 출력에 '$want'" ;; *) ng "점검 출력에 '$want' 없음" ;; esac
done
if [ -e "$IH/defaults" ] || [ -e "$IH/.agents" ]; then ng "터미널이 아닌데 무언가를 바꿈"; else ok "터미널이 아니면 아무것도 바꾸지 않음"; fi
if command -v script >/dev/null 2>&1 && script -qec true /dev/null >/dev/null 2>&1; then
  # 가상 터미널로 답을 넣습니다: 권한 옵션은 n, 스킬은 y
  fresh; fake codex
  printf 'n\ny\n' | script -qec "env HOME='$IH' PATH='$IH/fakebin:/usr/bin:/bin' AW_DEFAULTS='$IH/defaults' '$AW' setup" /dev/null >/dev/null 2>&1
  if [ -e "$IH/defaults" ]; then ng "n 이라 했는데 권한 옵션을 켬"; else ok "권한 옵션은 n 이면 켜지 않음"; fi
  if [ -f "$IH/.agents/skills/agent-worker/SKILL.md" ]; then ok "스킬은 y 면 넣음"; else ng "y 라 했는데 스킬을 안 넣음"; fi
  fresh; fake codex
  printf 'y\n\n' | script -qec "env HOME='$IH' PATH='$IH/fakebin:/usr/bin:/bin' AW_DEFAULTS='$IH/defaults' '$AW' setup" /dev/null >/dev/null 2>&1
  if [ -f "$IH/defaults" ]; then ok "권한 옵션은 y 면 켬"; else ng "y 라 했는데 권한 옵션을 안 켬"; fi
  if [ -e "$IH/.agents" ]; then ng "Enter(기본 아니오)인데 스킬을 넣음"; else ok "새 스킬은 그냥 Enter 면 넣지 않음 (기본 아니오)"; fi
  # 이미 넣은 스킬을 새 버전으로 바꾸는 건 기본 예
  fresh; fake codex
  awh skill install >/dev/null 2>&1; printf '추가된 줄\n' >> "$IH/.agents/skills/agent-worker/SKILL.md"
  printf '\n\n' | script -qec "env HOME='$IH' PATH='$IH/fakebin:/usr/bin:/bin' AW_DEFAULTS='$IH/defaults' '$AW' setup" /dev/null >/dev/null 2>&1
  check "옛 버전은 그냥 Enter 면 최신으로 (기본 예)" 최신 "$(state_of_agent codex)"
else
  echo "  (script 없음: 대화형 점검 시험 생략)"
fi

head_ "18. 진행 상황 (aw peek / aw watch)"
has() { case "$2" in *"$3"*) ok "$1" ;; *) ng "$1 (출력: $(printf '%s' "$2" | head -12 | tr '\n' '|'))" ;; esac; }
hasnt() { case "$2" in *"$3"*) ng "$1" ;; *) ok "$1" ;; esac; }

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
"$AW" wait pk-tree pk-claude pk-codex pk-agy pk-text pk-oneline pk-wt pk-mac --timeout 20 >/dev/null 2>&1
[ -n "$(command -v bash)" ] && "$AW" wait pk-mcp --timeout 20 >/dev/null 2>&1
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

printf '\n통과 %d / 실패 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
