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

AW_VERSION=0.4.0
AW_HOME="${AW_HOME:-$HOME/.local/share/agent-worker}"
AW_WORKERS="$AW_HOME/workers"
AW_CONFIG="${AW_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-worker/contexts}"
AW_DEFAULTS="${AW_DEFAULTS:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-worker/defaults}"

die()  { printf '%s\n' "$*" >&2; exit 1; }
warn() { printf '%s\n' "$*" >&2; }
say()  { printf '%s\n' "$*"; }

usage() {
  cat <<'USAGE'
사용법: aw <명령> [옵션]

  run [옵션] -- <실행할 명령...>   워커를 백그라운드로 띄웁니다
    -n, --name <이름>       워커 이름 (기본: 명령 이름 + 번호)
    -d, --dir <경로>        실행 디렉터리 (기본: 현재 디렉터리)
    -w, --worktree <브랜치> git worktree 를 만들어 거기서 실행
    -f, --stdin-file <파일> 이 파일을 표준 입력으로 물립니다 (기본: /dev/null)
    -e, --env KEY=VAL       환경변수 (여러 번 쓸 수 있음)
        --tag <문자열>      분류용 꼬리표
        --profile <이름>    CLAUDE_CONFIG_DIR 을 그 프로필로 (claude 편의)
        --max-input-tokens N  입력이 이 값을 넘을 것 같으면 경고 (0 이면 끄기)
        --no-defaults       에이전트별 기본 옵션을 붙이지 않음

  list [--json]             워커 목록과 상태
  status <이름>             워커 하나의 상세
  logs <이름> [-f] [-n N]   표준 출력 보기 (-f 는 따라가기)
  errs <이름> [-n N]        표준 오류 보기
  result <이름> [--field K] 출력 전문 (--field 는 JSON 최상위 문자열 하나)
  wait <이름...> [--timeout N]  끝날 때까지 기다립니다
  stop <이름...>            워커를 멈춥니다
  rm <이름...>              기록을 지웁니다 (worktree 도 함께)
  clean [--all]             끝난 워커를 한꺼번에 정리 (--all 은 실행 중도 멈춤)
  contexts                  에이전트별 컨텍스트 한도 표를 보여줍니다
  defaults                  에이전트별 기본 옵션 표를 보여줍니다
  version

워커 기록: $AW_HOME/workers/<이름>/
  meta  cmd  out  err  exit  run.sh
USAGE
}

# ---------------------------------------------------------------- 유틸

# 셸에 안전하게 넘길 수 있게 작은따옴표로 감쌉니다.
shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
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
# 그래서 에이전트별로 "사람 없이 돌 때" 필요한 옵션을 뒤에 붙여 줍니다.
# 붙인 내용은 실행할 때 화면에 찍고, --no-defaults 로 끌 수 있습니다.
# $AW_DEFAULTS 파일로 덮어쓰거나 새 에이전트를 추가할 수 있습니다.
builtin_defaults() {
  cat <<'DEF'
# 명령이름  뒤에 붙일 옵션들
agy --dangerously-skip-permissions
claude --permission-mode bypassPermissions
devin --permission-mode dangerous
codex --sandbox workspace-write
DEF
}

defaults_for() { # <명령 이름>
  cmd=${1##*/}
  { builtin_defaults; [ -f "$AW_DEFAULTS" ] && cat "$AW_DEFAULTS"; } \
    | sed 's/#.*//' \
    | awk -v c="$cmd" '$1 == c { $1 = ""; sub(/^ +/, ""); v = $0 } END { if (v != "") print v }'
}

cmd_defaults() {
  say "에이전트별 기본 옵션 (명령 뒤에 붙습니다)"
  say ""
  { builtin_defaults; [ -f "$AW_DEFAULTS" ] && { say ""; say "# --- $AW_DEFAULTS ---"; cat "$AW_DEFAULTS"; }; }
  say ""
  say "바꾸려면: $AW_DEFAULTS 에 '명령이름 옵션...' 을 적으세요."
  say "한 번만 끄려면: aw run --no-defaults ..."
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
      -e | --env)        envs="$envs $(shquote "${2:?--env 에 KEY=VAL 이 필요합니다}")"; shift 2 ;;
      --tag)             tag="${2:?--tag 에 값이 필요합니다}"; shift 2 ;;
      --profile)         profile="${2:?--profile 에 이름이 필요합니다}"; shift 2 ;;
      --max-input-tokens) max_tokens="${2:?--max-input-tokens 에 숫자가 필요합니다}"; shift 2 ;;
      --no-defaults)     no_defaults=1; shift ;;
      -*) die "알 수 없는 옵션: $1" ;;
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
      *) envs="$envs $(shquote "CLAUDE_CONFIG_DIR=${CLAUDE_PROFILE_ROOT:-$HOME/.claude-profiles}/$profile")" ;;
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
    for e in $envs; do printf 'export %s\n' "$e"; done
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
  defaults) cmd_defaults ;;
  version|--version|-v) say "aw $AW_VERSION" ;;
  help|--help|-h) usage ;;
  *) die "알 수 없는 명령: $sub   (aw help)" ;;
esac
