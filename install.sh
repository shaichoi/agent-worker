#!/bin/sh
# aw 설치 — 실행 파일 하나를 PATH 에 놓습니다.
#
# 셸 설정 파일을 건드리지 않습니다. rc 등록도, source 도 필요 없습니다.
# 여러 번 실행해도 안전합니다.

set -eu

RAW_URL="${AW_RAW_URL:-https://raw.githubusercontent.com/shaichoi/agent-worker/main/aw}"
PREFIX="${AW_PREFIX:-$HOME/.local/bin}"
DRY_RUN=0
WITH_DEFAULTS=1

usage() {
  cat <<'USAGE'
사용법: ./install.sh [옵션]

  --prefix DIR   설치 위치 (기본: ~/.local/bin)
  --no-defaults  무인 실행용 권한 옵션을 켜지 않음 (아래 설명 참고)
  --dry-run      무엇을 할지 보여주기만 함
  -h, --help     이 도움말

워커 기록(~/.local/share/agent-worker)은 설치·제거와 무관하게 유지됩니다.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)   PREFIX="${2:?--prefix 에 경로가 필요합니다}"; shift 2 ;;
    --prefix=*) PREFIX="${1#--prefix=}"; shift ;;
    --no-defaults) WITH_DEFAULTS=0; shift ;;
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

# curl ... | sh 로 실행하면 옆에 aw 가 없습니다. 그때는 받아옵니다.
if [ ! -f "$SRC" ]; then
  say "옆에 aw 가 없어 내려받습니다: $RAW_URL"
  TMP=$(mktemp "${TMPDIR:-/tmp}/aw.XXXXXX")
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$RAW_URL" -o "$TMP" || { rm -f "$TMP"; warn "내려받기 실패"; exit 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP" "$RAW_URL" || { rm -f "$TMP"; warn "내려받기 실패"; exit 1; }
  else
    rm -f "$TMP"; warn "curl 또는 wget 이 필요합니다."; exit 1
  fi
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
[ -n "$TMP" ] && rm -f "$TMP"

say "== 3. 무인 실행용 권한 옵션"
if [ "$WITH_DEFAULTS" -eq 0 ]; then
  say "  건너뜀 (--no-defaults). 나중에 켜려면: aw defaults --init"
elif [ "$DRY_RUN" -eq 1 ]; then
  say "  aw defaults --init 을 실행할 예정 (끄려면 --no-defaults)"
else
  "$PREFIX/aw" defaults --init | sed 's/^/  /'
  say "  이 설정을 원하지 않으면 그 파일을 지우면 됩니다."
fi

say "== 4. PATH 확인"
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
권한 옵션 확인/끄기: aw defaults
제거: ./uninstall.sh   (워커 기록은 남습니다)
DONE
