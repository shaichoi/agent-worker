#!/bin/sh
# aw — 아무 CLI 명령이나 백그라운드 워커로 돌리고 추적하는 러너
#
# 에이전트 종류를 가리지 않습니다. claude, codex, aider, 빌드 스크립트 모두
# 같은 방식으로 돌립니다. 실행 디렉터리, 표준 입력, 환경변수, git worktree 만
# 챙겨 주고 나머지는 명령에 그대로 맡깁니다.
#
#   aw run -- claude -p --output-format json
#   aw run -n refactor -w feat/x -f task.md -- claude -p
#   aw list ; aw wait refactor ; aw result refactor

set -eu

AW_VERSION=0.6.0
AW_HOME="${AW_HOME:-$HOME/.local/share/agent-worker}"
AW_WORKERS="$AW_HOME/workers"
AW_CONFIG="${AW_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-worker/contexts}"
AW_DEFAULTS="${AW_DEFAULTS:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-worker/defaults}"

die()  { printf '%s\n' "$*" >&2; exit 1; }
warn() { printf '%s\n' "$*" >&2; }
say()  { printf '%s\n' "$*"; }

usage() {
  cat <<'USAGE'
aw — 아무 CLI 명령이나 백그라운드 워커로 돌리고 추적합니다.

사용법
  aw run [옵션] -- <실행할 명령...>    워커를 띄웁니다 (바로 반환)
  aw list [--json]                     목록과 상태
  aw wait <이름...> [--timeout N]      끝날 때까지 대기 (종료 코드로 성패)
  aw result <이름> [--field KEY]       출력 전문, 또는 JSON 필드 하나
  aw logs|errs <이름> [-f] [-n N]      표준 출력 / 표준 오류
  aw status <이름>                     상세 정보
  aw stop|rm <이름...>                 중단 / 기록 삭제
  aw clean [--all]                     끝난 워커 일괄 정리
  aw contexts                          컨텍스트 한도표
  aw defaults [--init]                 기본 옵션표 / 권한 우회 켜기
  aw version | aw help [주제]

전형적인 흐름
  aw run -n job -- claude -p --output-format json "작업 내용"
  aw wait job && aw result job --field result
  aw rm job

run 옵션
  -n 이름     -d 디렉터리     -w 브랜치(worktree 격리)
  -f 파일     표준 입력으로 물림 (기본 /dev/null 이라 멈추지 않음)
  -e K=V      환경변수        --profile 이름   CLAUDE_CONFIG_DIR 지정
  --tag 문자열                --max-input-tokens N   --no-defaults

상태: running / done(0) / failed(≠0) / stopped(aw stop) / lost(코드 없이 사라짐)
wait 종료 코드: 0 전부 성공 / 1 하나 이상 실패 / 2 시간 초과

자세히
  aw help agents    에이전트별 호출법과 함정 (claude, agy, devin, codex)
  aw help defaults  자동으로 붙는 권한 옵션
  aw help files     워커 기록 파일 구조
  aw help limits    프롬프트 크기와 컨텍스트 한도
USAGE
}

help_topic() {
  case "$1" in
    agents) cat <<'T'
에이전트별 호출법 (aw 는 명령을 그대로 넘깁니다)

claude — Claude Code
  aw run -n c1 -- claude -p --output-format json "작업"
  aw result c1 --field result        # 성공 여부: --field is_error
  계정 분리: aw run --profile work-sub -- claude -p "작업"

agy — Antigravity CLI (Gemini)
  aw run -n a1 -- agy --output-format json --model gemini-3.8-flash-high -p='작업'
  aw result a1 --field response      # 상태: --field status (SUCCESS)
  함정: -p 는 바로 다음 토큰을 프롬프트로 먹습니다.
        -p='작업' 형태로 붙이면 플래그 순서와 무관합니다.
        일반 텍스트는 stdin 으로 못 넣습니다 (-f 대신 인자로).
  모델 목록: agy models

devin
  aw run -n d1 -- devin -p "작업" --model gemini-3-8-flash-high
  함정: 프롬프트는 -p 바로 뒤에 와야 합니다.
        디렉터리마다 devin 을 한 번 대화형 실행해 신뢰 등록이 필요합니다.
  모델 목록: devin models list

codex — OpenAI Codex CLI
  aw run -n x1 -- codex exec --json "작업"
  aw run -n x2 -f spec.md -- codex exec --json -    # stdin 을 - 로 받습니다
  큰 프롬프트를 넣을 수 있는 유일한 경로입니다 (127KB 인자 제한 회피).

GUI 도구(Antigravity IDE, Cursor)는 창만 열려서 워커로 쓸 수 없습니다.
T
      ;;
    defaults) cmd_defaults ;;
    files) printf '워커 기록: %s/<이름>/\n\n' "$AW_WORKERS"; cat <<'T'

  meta      이름, 디렉터리, 시작 시각, worktree, 꼬리표, 토큰 추정치
  cmd       실행한 인자 (한 줄에 하나)
  out / err 표준 출력 / 표준 오류
  exit      종료 코드 (이 파일이 생기면 끝난 것)
  pid       프로세스 그룹 리더 (aw stop 이 이 그룹을 종료)
  run.sh    실제로 돌린 스크립트 (그대로 다시 실행 가능)

기계로 읽으려면: aw list --json
환경변수: AW_HOME, AW_CONFIG, AW_DEFAULTS, AW_NO_DEFAULTS
T
      ;;
    limits) cat <<'T'
프롬프트 크기
  리눅스는 인자 하나를 128KB 로 제한합니다 (MAX_ARG_STRLEN).
  127KB 까지 통과하고 그 이상은 셸이 argument list too long 으로 거부합니다.
  aw 가 실행되기 전에 걸리는 문제라 aw 가 대신 처리할 수 없습니다.

  ~127KB      -- agy -p="$(cat spec.md)"
  그 이상     파일을 두고 짧게 가리키기: -p='spec.md 의 지시를 따라라'
  stdin 지원  aw run -f spec.md -- codex exec --json -

컨텍스트 한도
  -f 로 넣는 입력이 에이전트 한도의 80% 를 넘으면 경고합니다 (막지는 않음).
  바이트 기준 어림값이고 저장소에서 읽는 파일은 세지 않습니다.
  표는 aw contexts, 한 번만 바꾸려면 --max-input-tokens N (0 이면 끄기).
T
      ;;
    '') usage ;;
    *) warn "그런 도움말 주제가 없습니다: $1"
       warn "쓸 수 있는 주제: agents, defaults, files, limits"
       return 1 ;;
  esac
}

# ---------------------------------------------------------------- 유틸

# 셸에 안전하게 넘길 수 있게 작은따옴표로 감쌉니다.
shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# 환경변수는 'export ...' 줄을 통째로 쌓습니다. 예전엔 공백으로 이어 붙인 뒤
# 셸의 단어 분리로 되꺼냈는데, 값에 공백이 있으면 줄이 쪼개져 조용히 깨졌습니다.
add_env() { # <KEY=VAL>
  envs="${envs}export $(shquote "$1")
"
}

valid_name() {
  case "$1" in
    '' | . | .. | .* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

wdir() { printf '%s\n' "$AW_WORKERS/$1"; }

need_worker() {
  valid_name "$1" || die "워커 이름이 잘못됐습니다: $1"
  [ -d "$(wdir "$1")" ] || die "그런 워커가 없습니다: $1   (aw list 로 확인)"
}

meta_get() { # <워커디렉터리> <키>
  [ -f "$1/meta" ] || return 0
  sed -n "s/^$2=//p" "$1/meta" | head -1
}

now() { date +%s; }

# 사람이 읽는 경과 시간
elapsed_str() { # <초>
  s=$1
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm%ds' $((s / 60)) $((s % 60))
  else printf '%dh%dm' $((s / 3600)) $(((s % 3600) / 60))
  fi
}

pid_alive() { kill -0 "$1" 2>/dev/null; }

# running | done | failed | stopped | lost
state_of() { # <워커디렉터리>
  d=$1
  if [ -f "$d/exit" ]; then
    code=$(cat "$d/exit" 2>/dev/null || printf '?')
    if [ "$(meta_get "$d" stopped)" = 1 ]; then printf 'stopped'
    elif [ "$code" = 0 ]; then printf 'done'
    else printf 'failed'
    fi
    return 0
  fi
  p=$(cat "$d/pid" 2>/dev/null || printf '')
  if [ -n "$p" ] && pid_alive "$p"; then printf 'running'; else printf 'lost'; fi
}

# JSON 문자열 값 하나 꺼내기 (jq/python 없이)
json_unescape() {
  awk '
    {
      s = $0; out = ""; i = 1; n = length(s)
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\" && i < n) {
          d = substr(s, i + 1, 1)
          if (d == "n")      { out = out "\n";            i += 2 }
          else if (d == "t") { out = out "\t";            i += 2 }
          else if (d == "r") { out = out "\r";            i += 2 }
          else if (d == "u") { out = out substr(s, i, 6); i += 6 }
          else               { out = out d;               i += 2 }
        } else { out = out c; i++ }
      }
      print out
    }
  '
}
json_str() { # <키>  (JSON 은 표준 입력)
  tr '\n' ' ' \
    | sed -n -E 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p' \
    | json_unescape
}
# 우리가 만드는 JSON 에 넣을 값 이스케이프
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'
}

# ---------------------------------------------------------------- 에이전트별 기본 옵션

# 무인 워커는 승인 프롬프트가 뜨면 그대로 멈추거나 조용히 거부됩니다.
# 그래서 에이전트별로 "사람 없이 돌 때" 필요한 옵션을 뒤에 붙일 수 있습니다.
#
# 다만 이건 권한을 올리는 일이라 aw 가 마음대로 하지 않습니다.
# $AW_DEFAULTS 파일이 있을 때만 적용합니다 (install.sh 가 설치 때 만들어 주고,
# aw defaults --init 로도 만듭니다). 파일이 없으면 아무 옵션도 붙지 않습니다.
# 붙인 내용은 실행할 때 화면에 찍고, --no-defaults 로 그때그때 끌 수 있습니다.

# 권장값. 그대로 적용되지는 않고 --init 로 파일에 써야 효력이 생깁니다.
recommended_defaults() {
  cat <<'DEF'
# aw 가 명령 뒤에 붙일 옵션입니다. 한 줄에 '명령이름 옵션...' 형식입니다.
# 이 옵션들은 에이전트의 승인 절차를 건너뜁니다. 지우면 그 에이전트는
# 승인이 필요한 작업에서 멈추거나 조용히 거부됩니다.
agy --dangerously-skip-permissions
claude --permission-mode bypassPermissions
devin --permission-mode dangerous
codex --sandbox workspace-write
DEF
}

defaults_for() { # <명령 이름>
  [ -f "$AW_DEFAULTS" ] || return 0
  cmd=${1##*/}
  sed 's/#.*//' "$AW_DEFAULTS" \
    | awk -v c="$cmd" '$1 == c { $1 = ""; sub(/^ +/, ""); v = $0 } END { if (v != "") print v }'
}

defaults_init() { # [--force]
  if [ -f "$AW_DEFAULTS" ] && [ "${1:-}" != --force ]; then
    say "이미 있습니다: $AW_DEFAULTS   (덮어쓰려면 aw defaults --init --force)"
    return 0
  fi
  mkdir -p "$(dirname "$AW_DEFAULTS")" || return 1
  recommended_defaults > "$AW_DEFAULTS" || return 1
  say "기본 옵션을 켰습니다: $AW_DEFAULTS"
  say "  이제 워커가 에이전트의 승인 절차를 건너뜁니다."
  say "  끄려면 그 파일을 지우거나 해당 줄을 주석 처리하세요."
  return 0
}

cmd_defaults() {
  case "${1:-}" in
    --init) defaults_init "${2:-}"; return $? ;;
    '') ;;
    *) warn "알 수 없는 옵션: $1   (쓸 수 있는 것: --init [--force])"; return 1 ;;
  esac

  if [ -f "$AW_DEFAULTS" ]; then
    say "적용 중인 기본 옵션  ($AW_DEFAULTS)"
    say ""
    sed 's/^/  /' "$AW_DEFAULTS"
    say ""
    say "끄려면: 이 파일을 지우거나 해당 줄을 주석 처리하세요."
    say "한 번만 끄려면: aw run --no-defaults ...   (또는 AW_NO_DEFAULTS=1)"
  else
    say "적용 중인 기본 옵션이 없습니다. 에이전트에 아무 옵션도 덧붙이지 않습니다."
    say ""
    say "무인 워커는 승인 프롬프트를 만나면 멈추거나 조용히 거부됩니다."
    say "아래 권장값을 켜려면: aw defaults --init"
    say ""
    recommended_defaults | sed 's/^/  /'
  fi
  say ""
  say "권한 우회는 그 에이전트가 승인 없이 파일을 고치고 명령을 실행한다는 뜻입니다."
  say "무인으로 돌릴 때는 -w 로 worktree 를 떼어 놓는 편을 권합니다."
}

# ---------------------------------------------------------------- 컨텍스트 한도

# 에이전트별 기본 컨텍스트 한도(토큰). 사용자가 $AW_CONFIG 로 덮어쓸 수 있습니다.
# 이 값은 도구의 동작을 바꾸지 않고 경고에만 씁니다.
default_contexts() {
  cat <<'CTX'
# 명령이름 토큰수   (# 은 주석)
# devin 자체 모델(SWE-2, SWE-1.7)은 262K 입니다.
# --model 로 Claude/GPT/Gemini 를 고르면 1M 이므로 그때는 --max-input-tokens 로 덮어쓰세요.
devin 262000
claude 1000000
agy 1000000
codex 400000
aider 200000
CTX
}

context_limit_for() { # <명령 이름>
  cmd=${1##*/}
  { default_contexts; [ -f "$AW_CONFIG" ] && cat "$AW_CONFIG"; } \
    | sed 's/#.*//' \
    | awk -v c="$cmd" '$1 == c { v = $2 } END { if (v != "") print v }'
}

# 바이트 수로 토큰 수를 어림잡습니다. 정확한 토크나이저가 아니라 안전한 쪽으로 봅니다.
# ASCII 는 4바이트/토큰, 한글 같은 비ASCII 는 2바이트/토큰으로 계산합니다.
estimate_tokens() { # <파일>
  total=$(wc -c < "$1" 2>/dev/null || printf 0)
  non=$(tr -d '\000-\177' < "$1" 2>/dev/null | wc -c)
  [ -n "$non" ] || non=0
  ascii=$((total - non))
  [ "$ascii" -lt 0 ] && ascii=0
  printf '%s\n' $((ascii / 4 + non / 2))
}

cmd_contexts() {
  say "에이전트별 컨텍스트 한도 (경고용 어림값, 토큰)"
  say ""
  { default_contexts; [ -f "$AW_CONFIG" ] && { say ""; say "# --- $AW_CONFIG ---"; cat "$AW_CONFIG"; }; }
  say ""
  say "바꾸려면: $AW_CONFIG 에 '명령이름 토큰수' 를 적으세요."
  say "한 번만 덮어쓰려면: aw run --max-input-tokens N ..."
}

# ---------------------------------------------------------------- run

cmd_run() {
  name=''; dir=''; worktree=''; stdin_file='/dev/null'; tag=''; profile=''
  envs=''; max_tokens=''; no_defaults="${AW_NO_DEFAULTS:-0}"; added=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      -n | --name)       name="${2:?--name 에 값이 필요합니다}"; shift 2 ;;
      -d | --dir)        dir="${2:?--dir 에 값이 필요합니다}"; shift 2 ;;
      -w | --worktree)   worktree="${2:?--worktree 에 브랜치 이름이 필요합니다}"; shift 2 ;;
      -f | --stdin-file) stdin_file="${2:?--stdin-file 에 파일이 필요합니다}"; shift 2 ;;
      -e | --env)        add_env "${2:?--env 에 KEY=VAL 이 필요합니다}"; shift 2 ;;
      --tag)             tag="${2:?--tag 에 값이 필요합니다}"; shift 2 ;;
      --profile)         profile="${2:?--profile 에 이름이 필요합니다}"; shift 2 ;;
      --max-input-tokens) max_tokens="${2:?--max-input-tokens 에 숫자가 필요합니다}"; shift 2 ;;
      --no-defaults)     no_defaults=1; shift ;;
      -h | --help) usage; return 0 ;;
      -*) die "알 수 없는 옵션: $1   (aw help)" ;;
      *)  break ;;
    esac
  done
  [ $# -gt 0 ] || die "실행할 명령이 없습니다.   예) aw run -- claude -p"

  # 이름 정하기
  if [ -z "$name" ]; then
    base=$(printf '%s' "${1##*/}" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-16)
    [ -n "$base" ] || base=worker
    i=1
    while [ -d "$AW_WORKERS/$base-$i" ]; do i=$((i + 1)); done
    name="$base-$i"
  fi
  valid_name "$name" || die "워커 이름은 영문/숫자/. _ - 만 쓸 수 있습니다: $name"
  wd=$(wdir "$name")
  [ -e "$wd" ] && die "이미 있는 워커입니다: $name   (aw rm $name 으로 지우세요)"

  # 실행 디렉터리
  [ -n "$dir" ] || dir=$PWD
  dir=$(CDPATH= cd -- "$dir" 2>/dev/null && pwd) || die "디렉터리를 찾을 수 없습니다: $dir"

  # 표준 입력 파일
  if [ "$stdin_file" != /dev/null ]; then
    [ -f "$stdin_file" ] || die "표준 입력 파일이 없습니다: $stdin_file"
    stdin_file=$(CDPATH= cd -- "$(dirname -- "$stdin_file")" && pwd)/$(basename -- "$stdin_file")
  fi

  # 프로필 편의 (claude 전용)
  if [ -n "$profile" ]; then
    case "$profile" in
      default) ;;
      *) add_env "CLAUDE_CONFIG_DIR=${CLAUDE_PROFILE_ROOT:-$HOME/.claude-profiles}/$profile" ;;
    esac
  fi

  mkdir -p "$wd" || die "워커 디렉터리를 만들 수 없습니다: $wd"

  # worktree 격리 (요청했을 때만)
  wt=''
  if [ -n "$worktree" ]; then
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || {
      rm -rf "$wd"; die "git 저장소가 아니라 worktree 를 만들 수 없습니다: $dir"
    }
    top=$(git -C "$dir" rev-parse --show-toplevel)
    wt="$top/.aw-worktrees/$name"
    if ! git -C "$top" worktree add -b "$worktree" "$wt" >/dev/null 2>&1; then
      rm -rf "$wd"
      die "worktree 를 만들지 못했습니다. 브랜치가 이미 있는지 확인하세요: $worktree"
    fi
    dir="$wt"
  fi

  # 에이전트별 기본 옵션을 뒤에 붙입니다.
  # 앞이 아니라 뒤에 붙이는 이유: agy 의 -p 는 바로 다음 토큰을 프롬프트로 먹습니다.
  if [ "$no_defaults" -ne 1 ]; then
    added=$(defaults_for "$1")
    if [ -n "$added" ]; then
      # 첫 토큰(플래그 이름)을 사용자가 이미 줬으면 그 줄 전체를 건너뜁니다.
      # --permission-mode bypassPermissions 처럼 값이 딸린 옵션이 반쪽만
      # 붙는 사고를 막습니다.
      first=${added%% *}
      for a in "$@"; do
        case "$a" in "$first" | "$first"=*) added=''; break ;; esac
      done
    fi
    if [ -n "$added" ]; then
      # 공백으로 직접 쪼갭니다. 셸의 단어 분리에 기대지 않습니다
      # (zsh 는 따옴표 없는 변수를 분리하지 않습니다).
      rest=$added
      while [ -n "$rest" ]; do
        tok=${rest%% *}
        case "$rest" in *' '*) rest=${rest#* } ;; *) rest='' ;; esac
        [ -n "$tok" ] && set -- "$@" "$tok"
      done
    fi
  fi

  # 실행 스크립트 만들기 (인자를 따옴표로 보존)
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '# aw 가 자동으로 만든 실행 스크립트입니다.'
    printf 'cd %s || { printf "127\\n" > %s/exit; exit 127; }\n' "$(shquote "$dir")" "$(shquote "$wd")"
    printf '%s' "$envs"
    printf 'printf "%%s\\n" "$$" > %s/pid\n' "$(shquote "$wd")"
    printf '%s' 'exec'
    for a in "$@"; do printf ' %s' "$(shquote "$a")"; done
    printf ' < %s > %s 2> %s\n' "$(shquote "$stdin_file")" "$(shquote "$wd/out")" "$(shquote "$wd/err")"
  } > "$wd/launch.sh"

  # exec 는 종료 코드를 남길 수 없으므로 한 겹 더 감쌉니다.
  {
    printf '%s\n' '#!/bin/sh'
    printf 'sh %s\n' "$(shquote "$wd/launch.sh")"
    printf 'code=$?\n'
    printf 'printf "%%s\\n" "$code" > %s/exit.tmp\n' "$(shquote "$wd")"
    printf 'mv %s/exit.tmp %s/exit\n' "$(shquote "$wd")" "$(shquote "$wd")"
    printf 'date +%%s > %s/finished\n' "$(shquote "$wd")"
  } > "$wd/run.sh"

  # 사람이 읽을 명령 기록
  : > "$wd/cmd"
  for a in "$@"; do printf '%s\n' "$a" >> "$wd/cmd"; done

  {
    printf 'name=%s\n' "$name"
    printf 'dir=%s\n' "$dir"
    printf 'started=%s\n' "$(now)"
    printf 'stdin=%s\n' "$stdin_file"
    [ -n "$tag" ]      && printf 'tag=%s\n' "$tag"
    [ -n "$profile" ]  && printf 'profile=%s\n' "$profile"
    [ -n "$wt" ]       && { printf 'worktree=%s\n' "$wt"; printf 'branch=%s\n' "$worktree"; }
    printf 'cmdline=%s\n' "$(printf '%s ' "$@" | sed 's/ $//' | tr '\n' ' ')"
  } > "$wd/meta"

  # 입력이 컨텍스트 한도를 넘을 것 같으면 알려 줍니다. 막지는 않습니다.
  if [ "$stdin_file" != /dev/null ]; then
    limit=$max_tokens
    [ -n "$limit" ] || limit=$(context_limit_for "$1")
    if [ -n "$limit" ] && [ "$limit" -gt 0 ] 2>/dev/null; then
      est=$(estimate_tokens "$stdin_file")
      printf 'input_tokens_est=%s\n' "$est" >> "$wd/meta"
      printf 'context_limit=%s\n' "$limit" >> "$wd/meta"
      if [ "$est" -gt $((limit * 8 / 10)) ]; then
        warn "경고: 입력이 약 ${est} 토큰으로 ${1##*/} 의 컨텍스트 한도 ${limit} 에 가깝습니다."
        warn "  (바이트 기준 어림값입니다. 에이전트가 읽을 저장소 파일은 포함되지 않았습니다.)"
        warn "  나눠서 넣거나 --max-input-tokens 로 한도를 조정하세요."
      fi
    fi
  fi

  # 셸에서 떼어내 실행 (대화형 셸의 작업 목록에 남지 않게)
  if command -v setsid >/dev/null 2>&1; then
    ( setsid sh "$wd/run.sh" </dev/null >/dev/null 2>&1 & )
  else
    ( nohup sh "$wd/run.sh" </dev/null >/dev/null 2>&1 & )
  fi

  # pid 파일이 생길 때까지 잠깐 기다립니다 (바로 list 를 봐도 보이도록)
  i=0
  while [ ! -f "$wd/pid" ] && [ ! -f "$wd/exit" ] && [ "$i" -lt 30 ]; do
    i=$((i + 1))
    sleep 0.1 2>/dev/null || sleep 1
  done

  say "워커 시작: $name"
  say "  디렉터리: $dir"
  [ -n "$wt" ] && say "  worktree: $wt  (브랜치 $worktree)"
  say "  명령: $(meta_get "$wd" cmdline)"
  [ -n "$added" ] && [ "$no_defaults" -ne 1 ] && say "  (기본 옵션이 붙었습니다: $added — 끄려면 --no-defaults)"
  say "  보기: aw logs $name -f    기다리기: aw wait $name    결과: aw result $name"
}

# ---------------------------------------------------------------- 조회

list_dirs() {
  [ -d "$AW_WORKERS" ] || return 0
  find "$AW_WORKERS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort
}

cmd_list() {
  as_json=0
  [ "${1:-}" = "--json" ] && as_json=1
  if [ "$as_json" -eq 1 ]; then
    printf '[\n'
    first=1
    list_dirs | while IFS= read -r d; do
      st=$(state_of "$d")
      started=$(meta_get "$d" started); [ -n "$started" ] || started=0
      fin=$(cat "$d/finished" 2>/dev/null || printf '')
      code=$(cat "$d/exit" 2>/dev/null || printf '')
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      printf '  {"name":"%s","state":"%s","exit":"%s","started":%s,"finished":"%s","dir":"%s","cmd":"%s"}' \
        "$(json_escape "$(meta_get "$d" name)")" "$st" "$code" "$started" "$fin" \
        "$(json_escape "$(meta_get "$d" dir)")" "$(json_escape "$(meta_get "$d" cmdline)")"
    done
    printf '\n]\n'
    return 0
  fi

  if [ -z "$(list_dirs)" ]; then
    say "워커가 없습니다.   예) aw run -- claude -p"
    return 0
  fi
  # 한글은 두 칸을 차지해서 %-18s 로는 안 맞습니다. 머리글은 직접 맞춥니다.
  printf '%s\n' '이름               상태     코드  경과     명령'
  list_dirs | while IFS= read -r d; do
    st=$(state_of "$d")
    started=$(meta_get "$d" started); [ -n "$started" ] || started=$(now)
    fin=$(cat "$d/finished" 2>/dev/null || printf '')
    [ -n "$fin" ] || fin=$(now)
    code=$(cat "$d/exit" 2>/dev/null || printf '-')
    printf '%-18s %-8s %-5s %-8s %s\n' \
      "$(meta_get "$d" name)" "$st" "$code" "$(elapsed_str $((fin - started)))" \
      "$(meta_get "$d" cmdline | cut -c1-60)"
  done
}

cmd_status() {
  need_worker "$1"
  d=$(wdir "$1")
  st=$(state_of "$d")
  started=$(meta_get "$d" started)
  fin=$(cat "$d/finished" 2>/dev/null || now)
  say "워커 $1"
  say "  상태     : $st$( [ -f "$d/exit" ] && printf ' (종료 코드 %s)' "$(cat "$d/exit")" )"
  say "  명령     : $(meta_get "$d" cmdline)"
  say "  디렉터리 : $(meta_get "$d" dir)"
  [ -n "$(meta_get "$d" worktree)" ] && say "  worktree : $(meta_get "$d" worktree)  (브랜치 $(meta_get "$d" branch))"
  [ -n "$(meta_get "$d" profile)" ]  && say "  프로필   : $(meta_get "$d" profile)"
  [ -n "$(meta_get "$d" tag)" ]      && say "  꼬리표   : $(meta_get "$d" tag)"
  say "  경과     : $(elapsed_str $((fin - started)))"
  say "  출력     : $d/out  ($(wc -c < "$d/out" 2>/dev/null || printf 0) bytes)"
  say "  오류     : $d/err  ($(wc -c < "$d/err" 2>/dev/null || printf 0) bytes)"
}

cmd_logs() {
  follow=0; lines=40; name=''
  while [ $# -gt 0 ]; do
    case "$1" in
      -f | --follow) follow=1; shift ;;
      -n) lines="${2:?-n 에 줄 수가 필요합니다}"; shift 2 ;;
      *) name=$1; shift ;;
    esac
  done
  [ -n "$name" ] || die "워커 이름이 필요합니다."
  need_worker "$name"
  f="$(wdir "$name")/${AW_LOG_FILE:-out}"
  [ -f "$f" ] || { warn "아직 출력이 없습니다."; return 0; }
  if [ "$follow" -eq 1 ]; then tail -n "$lines" -f "$f"; else tail -n "$lines" "$f"; fi
}

cmd_errs() { AW_LOG_FILE=err; export AW_LOG_FILE; cmd_logs "$@"; }

cmd_result() {
  name=''; field=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --field) field="${2:?--field 에 키가 필요합니다}"; shift 2 ;;
      *) name=$1; shift ;;
    esac
  done
  [ -n "$name" ] || die "워커 이름이 필요합니다."
  need_worker "$name"
  d=$(wdir "$name")
  [ -f "$d/out" ] || die "출력이 없습니다: $name"
  if [ -n "$field" ]; then
    json_str "$field" < "$d/out"
  else
    cat "$d/out"
  fi
}

cmd_wait() {
  timeout=0; names=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="${2:?--timeout 에 초가 필요합니다}"; shift 2 ;;
      *) names="$names $1"; shift ;;
    esac
  done
  [ -n "$names" ] || die "기다릴 워커 이름이 필요합니다."
  for n in $names; do need_worker "$n"; done
  start=$(now)
  rc=0
  for n in $names; do
    d=$(wdir "$n")
    while [ ! -f "$d/exit" ]; do
      p=$(cat "$d/pid" 2>/dev/null || printf '')
      if [ -n "$p" ] && ! pid_alive "$p" && [ ! -f "$d/exit" ]; then
        sleep 1
        [ -f "$d/exit" ] || { warn "$n: 프로세스가 사라졌습니다 (lost)"; rc=1; break; }
      fi
      if [ "$timeout" -gt 0 ] && [ $(( $(now) - start )) -ge "$timeout" ]; then
        warn "시간 초과로 기다리기를 멈춥니다: $n"
        return 2
      fi
      sleep 1
    done
    if [ -f "$d/exit" ]; then
      code=$(cat "$d/exit")
      say "$n: $(state_of "$d") (종료 코드 $code)"
      [ "$code" = 0 ] || rc=1
    fi
  done
  return $rc
}

cmd_stop() {
  [ $# -gt 0 ] || die "멈출 워커 이름이 필요합니다."
  for n in "$@"; do
    need_worker "$n"
    d=$(wdir "$n")
    if [ -f "$d/exit" ]; then say "$n: 이미 끝났습니다."; continue; fi
    p=$(cat "$d/pid" 2>/dev/null || printf '')
    if [ -z "$p" ]; then say "$n: 프로세스를 찾을 수 없습니다."; continue; fi
    kill -TERM "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
    i=0
    while [ "$i" -lt 10 ] && pid_alive "$p"; do i=$((i + 1)); sleep 0.3 2>/dev/null || sleep 1; done
    pid_alive "$p" && { kill -KILL "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true; }
    printf 'stopped=1\n' >> "$d/meta"
    [ -f "$d/exit" ] || printf '143\n' > "$d/exit"
    [ -f "$d/finished" ] || now > "$d/finished"
    say "$n: 멈췄습니다."
  done
}

remove_worker() { # <이름>
  d=$(wdir "$1")
  wt=$(meta_get "$d" worktree)
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || printf '')
    if [ -n "$top" ]; then
      git -C "$top" worktree remove --force "$wt" >/dev/null 2>&1 \
        || warn "worktree 를 지우지 못했습니다: $wt"
    fi
  fi
  rm -rf "$d"
}

cmd_rm() {
  [ $# -gt 0 ] || die "지울 워커 이름이 필요합니다."
  for n in "$@"; do
    need_worker "$n"
    d=$(wdir "$n")
    [ "$(state_of "$d")" = running ] && die "$n 은 아직 실행 중입니다. aw stop $n 부터 하세요."
    remove_worker "$n"
    say "지움: $n"
  done
}

cmd_clean() {
  all=0
  [ "${1:-}" = "--all" ] && all=1
  found=0
  for d in $(list_dirs); do
    n=$(meta_get "$d" name)
    st=$(state_of "$d")
    if [ "$st" = running ]; then
      [ "$all" -eq 1 ] || continue
      cmd_stop "$n" >/dev/null
    fi
    remove_worker "$n"
    say "지움: $n ($st)"
    found=1
  done
  [ "$found" -eq 0 ] && say "정리할 워커가 없습니다."
  return 0
}

# ---------------------------------------------------------------- 진입점

mkdir -p "$AW_WORKERS" 2>/dev/null || die "작업 디렉터리를 만들 수 없습니다: $AW_WORKERS"

[ $# -gt 0 ] || { usage; exit 1; }
sub=$1; shift
case "$sub" in
  run)     cmd_run "$@" ;;
  list|ls) cmd_list "$@" ;;
  status)  [ $# -gt 0 ] || die "워커 이름이 필요합니다."; cmd_status "$@" ;;
  logs)    cmd_logs "$@" ;;
  errs)    cmd_errs "$@" ;;
  result)  cmd_result "$@" ;;
  wait)    cmd_wait "$@" ;;
  stop)    cmd_stop "$@" ;;
  rm)      cmd_rm "$@" ;;
  clean)   cmd_clean "$@" ;;
  contexts) cmd_contexts ;;
  defaults) cmd_defaults "$@" ;;
  version|--version|-v) say "aw $AW_VERSION" ;;
  help|--help|-h) help_topic "${1:-}" ;;
  *) die "알 수 없는 명령: $sub   (aw help)" ;;
esac
