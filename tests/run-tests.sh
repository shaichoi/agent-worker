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

head_ "15. 세션 ID 기록"
RSTUB="$TMPROOT/rstub"
mkdir -p "$RSTUB"
printf '#!/bin/sh\nprintf "{\\"session_id\\":\\"SID1\\",\\"result\\":\\"ok\\"}\\n"\n' > "$RSTUB/claude"
printf '#!/bin/sh\nprintf "{\\"conversation_id\\":\\"CID1\\"}\\n"\n' > "$RSTUB/agy"
printf '#!/bin/sh\nprintf "{\\"thread_id\\":\\"TID1\\"}\\n"\n' > "$RSTUB/codex"
printf '#!/bin/sh\necho 텍스트만\n' > "$RSTUB/devin"
chmod +x "$RSTUB"/*
PATH="$RSTUB:$PATH"; export PATH
"$AW" clean --all >/dev/null 2>&1
for a in claude:SID1 agy:CID1 codex:TID1; do
  n=${a%%:*}; want=${a#*:}
  "$AW" run -n "sess-$n" -- "$n" >/dev/null 2>&1
  "$AW" wait "sess-$n" >/dev/null 2>&1
  case "$("$AW" status "sess-$n")" in *"$want"*) ok "$n 의 세션 ID 를 찾음 ($want)" ;; *) ng "$n 의 세션 ID 를 못 찾음" ;; esac
  check "$n: 한 번 찾으면 meta 에 적어 둠" "$want" "$(sed -n 's/^session=//p' "$AW_HOME/workers/sess-$n/meta")"
done
case "$("$AW" list --json)" in *'"session":"SID1"'*) ok "list --json 에 session 필드" ;; *) ng "list --json 에 session 없음" ;; esac
"$AW" run -n sess-devin -- devin >/dev/null 2>&1
"$AW" wait sess-devin >/dev/null 2>&1
check "텍스트만 내놓으면 빈 값" "" "$(sed -n 's/^session=//p' "$AW_HOME/workers/sess-devin/meta")"
"$AW" clean --all >/dev/null 2>&1

printf '\n통과 %d / 실패 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
