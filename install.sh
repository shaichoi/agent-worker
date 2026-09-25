#!/bin/sh
# aw 설치 — 실행 파일 하나를 PATH 에 놓습니다.
#
# 셸 설정 파일을 건드리지 않습니다. rc 등록도, source 도 필요 없습니다.
# 에이전트들이 aw 를 쓸 수 있게 하는 스킬(SKILL.md)은 묻고 넣습니다 (기본 아니오).
# 여러 번 실행해도 안전합니다.

set -eu

RAW_URL="${AW_RAW_URL:-https://raw.githubusercontent.com/shaichoi/agent-worker/main/aw}"
PREFIX="${AW_PREFIX:-$HOME/.local/bin}"
DRY_RUN=0
WITH_DEFAULTS=1
WITH_BRIEF=1
SKILL_MODE=ask     # ask | all | list | none
SKILL_NAMES=''

usage() {
  cat <<'USAGE'
사용법: ./install.sh [옵션]

  --prefix DIR   설치 위치 (기본: ~/.local/bin)
  --no-defaults  무인 실행용 권한 옵션을 켜지 않음 (아래 설명 참고)
  --no-brief     워커 지시문(예상 소요 시간 먼저 등)을 켜지 않음
  --skill        찾은 에이전트 전부에 스킬을 묻지 않고 넣음
  --skill=A,B    고른 에이전트에만 넣음 (claude, codex, devin, agy, hermes)
  --no-skill     스킬은 아예 건드리지 않음
  --dry-run      무엇을 할지 보여주기만 함
  -h, --help     이 도움말

스킬은 옵션이 없으면 터미널에서 에이전트마다 묻고 넣습니다 (기본 아니오).
터미널이 없으면(스크립트, CI) 새로 넣지 않습니다. 이미 넣어 둔 스킬은 새 버전으로
바꿉니다. 나중에 보거나 바꾸려면 aw skill, 설치 전반 점검은 aw setup.

워커 기록(~/.local/share/agent-worker)은 설치·제거와 무관하게 유지됩니다.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)   PREFIX="${2:?--prefix 에 경로가 필요합니다}"; shift 2 ;;
    --prefix=*) PREFIX="${1#--prefix=}"; shift ;;
    --no-defaults) WITH_DEFAULTS=0; shift ;;
    --no-brief) WITH_BRIEF=0; shift ;;
    --skill)    SKILL_MODE=all; shift ;;
    --skill=*)  SKILL_MODE=list; SKILL_NAMES=$(printf '%s' "${1#--skill=}" | tr ',' ' '); shift ;;
    --no-skill) SKILL_MODE=none; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) printf '알 수 없는 옵션: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC="$SRC_DIR/aw"
TMP=''
trap 'rm -f "$TMP"' EXIT

fetch() { # <URL> <저장할 파일>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    warn "curl 또는 wget 이 필요합니다."; return 1
  fi
}

# curl ... | sh 로 실행하면 옆에 aw 가 없습니다. 그때는 받아옵니다.
if [ ! -f "$SRC" ]; then
  say "옆에 aw 가 없어 내려받습니다: $RAW_URL"
  TMP=$(mktemp "${TMPDIR:-/tmp}/aw.XXXXXX")
  fetch "$RAW_URL" "$TMP" || { warn "내려받기 실패"; exit 1; }
  SRC="$TMP"
fi

say "== 1. 문법 확인"
sh -n "$SRC" || { warn "스크립트 문법이 잘못됐습니다. 설치를 중단합니다."; exit 1; }
say "  통과"

say "== 2. 설치"
say "  대상: $PREFIX/aw"
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$PREFIX"
  cp "$SRC" "$PREFIX/aw.new"
  chmod 755 "$PREFIX/aw.new"
  mv "$PREFIX/aw.new" "$PREFIX/aw"
  say "  완료: $("$PREFIX/aw" version)"
fi

say "== 3. 무인 실행용 권한 옵션"
if [ "$WITH_DEFAULTS" -eq 0 ]; then
  say "  건너뜀 (--no-defaults). 나중에 켜려면: aw defaults --init"
elif [ "$DRY_RUN" -eq 1 ]; then
  say "  aw defaults --init 을 실행할 예정 (끄려면 --no-defaults)"
else
  "$PREFIX/aw" defaults --init | sed 's/^/  /'
  say "  이 설정을 원하지 않으면 그 파일을 지우면 됩니다."
fi

say "== 4. 워커 지시문"
# 워커 프롬프트 앞에 붙는 지시문입니다. 예상 소요 시간을 먼저 적고, 오래 걸리면 중간중간
# 진행을 남기게 합니다. 기존 파일은 그대로 둡니다 (aw brief --init 은 덮어쓰지 않음).
if [ "$WITH_BRIEF" -eq 0 ]; then
  say "  건너뜀 (--no-brief). 나중에 켜려면: aw brief --init"
elif [ "$DRY_RUN" -eq 1 ]; then
  say "  aw brief --init 을 실행할 예정 (끄려면 --no-brief)"
else
  "$PREFIX/aw" brief --init | sed 's/^/  /'
fi

say "== 5. 에이전트 스킬"
# 스킬 내용은 aw 안에 있습니다. 어느 에이전트가 어느 폴더를 읽는지도 aw 가 압니다 (aw skill).
# 스킬은 에이전트가 읽는 지시문이라 묻지 않고 넣지 않습니다. 스킬은 덤이라 실패해도 설치는 끝까지 갑니다.
skill_cmd() { # <aw skill 인자...>
  if [ "$DRY_RUN" -eq 1 ]; then
    # aw 는 시작할 때 워커 기록 폴더를 만듭니다. dry-run 에서는 임시 폴더로 돌립니다.
    DRY_HOME=$(mktemp -d "${TMPDIR:-/tmp}/aw-dry.XXXXXX")
    AW_HOME="$DRY_HOME" sh "$SRC" skill "$@" --dry-run
    rm -rf "$DRY_HOME"
  else
    "$PREFIX/aw" skill "$@"
  fi
}
# curl ... | sh 로 돌면 표준 입력은 이 스크립트라서, 물을 때는 /dev/tty 로 받습니다.
can_ask() { [ -t 1 ] && (: < /dev/tty) 2>/dev/null; }
case "$SKILL_MODE" in
  none)
    say "  건너뜀 (--no-skill). 나중에 넣으려면: aw skill install" ;;
  all | list)
    # shellcheck disable=SC2086  # 이름 목록은 일부러 쪼갭니다
    skill_cmd install $SKILL_NAMES || warn "  스킬을 넣지 못했습니다. 나중에: aw skill install" ;;
  ask)
    skill_cmd update --quiet || warn "  스킬을 바꾸지 못했습니다. 나중에: aw skill update"
    if [ "$DRY_RUN" -eq 1 ]; then
      say "  (실제 설치 때는 새로 넣을 곳마다 묻습니다)"
      skill_cmd install || true
    elif can_ask; then
      skill_cmd install --ask < /dev/tty || warn "  스킬을 넣지 못했습니다. 나중에: aw skill install"
    else
      say "  새로 넣지 않았습니다 (터미널이 아니라 물어볼 수 없음)."
      say "  넣으려면: aw skill install [에이전트...]   또는 설치 때 --skill"
    fi ;;
esac

say "== 6. PATH 확인"
case ":$PATH:" in
  *":$PREFIX:"*) say "  $PREFIX 는 이미 PATH 에 있습니다." ;;
  *)
    warn "  $PREFIX 가 PATH 에 없습니다. 셸 설정에 아래 줄을 넣으세요:"
    warn "    export PATH=\"$PREFIX:\$PATH\""
    ;;
esac

cat <<DONE

써 보기:
  aw run -- claude -p --output-format json "무엇이든"
  aw list
  aw wait <이름> && aw result <이름> --field result

도움말: aw help          에이전트별 호출법: aw help agents
설치 점검: aw setup      에이전트 스킬: aw skill
권한 옵션 확인/끄기: aw defaults   지시문 확인/고치기: aw brief
제거: ./uninstall.sh   (워커 기록은 남습니다)
DONE
