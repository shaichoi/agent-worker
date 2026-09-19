#!/bin/sh
# aw 제거
#
# 기본은 실행 파일만 지웁니다. 워커 기록(출력, 종료 코드)은 남깁니다.

set -eu

PREFIX="${AW_PREFIX:-$HOME/.local/bin}"
AW_HOME="${AW_HOME:-$HOME/.local/share/agent-worker}"
PURGE=0
ASSUME_YES=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
사용법: ./uninstall.sh [옵션]

  --prefix DIR   설치 위치 (기본: ~/.local/bin)
  --purge        워커 기록(출력과 종료 코드)까지 삭제
  --yes          --purge 확인 질문 건너뛰기
  --dry-run      무엇을 지울지 보여주기만 함
  -h, --help     이 도움말
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)   PREFIX="${2:?--prefix 에 경로가 필요합니다}"; shift 2 ;;
    --prefix=*) PREFIX="${1#--prefix=}"; shift ;;
    --purge)    PURGE=1; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) printf '알 수 없는 옵션: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

say "== 실행 파일"
if [ -f "$PREFIX/aw" ]; then
  say "  삭제: $PREFIX/aw"
  [ "$DRY_RUN" -eq 0 ] && rm -f "$PREFIX/aw"
else
  say "  $PREFIX/aw 없음"
fi

say "== 설정 파일"
for f in "${XDG_CONFIG_HOME:-$HOME/.config}/agent-worker/defaults" "${XDG_CONFIG_HOME:-$HOME/.config}/agent-worker/contexts"; do
  [ -f "$f" ] && say "  남김: $f   (지우려면 rm \"$f\")"
done

say "== 워커 기록"
case "$AW_HOME" in
  "$HOME" | "$HOME/" | / | '') warn "  위험한 경로라 건드리지 않습니다: $AW_HOME"; PURGE=0 ;;
esac

if [ ! -d "$AW_HOME" ]; then
  say "  $AW_HOME 없음"
elif [ "$PURGE" -eq 0 ]; then
  n=$(find "$AW_HOME/workers" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  say "  유지: $AW_HOME  (워커 $n 개)"
  say "  기록까지 지우려면: ./uninstall.sh --purge"
else
  say "  아래를 삭제합니다:"
  find "$AW_HOME/workers" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort | sed 's/^/    /'
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  dry-run 이라 지우지 않습니다."
  elif [ "$ASSUME_YES" -eq 1 ]; then
    rm -rf "$AW_HOME"; say "  삭제 완료"
  elif [ -t 0 ]; then
    printf '정말 삭제할까요? yes 를 입력하세요: '
    read -r answer
    if [ "$answer" = yes ]; then rm -rf "$AW_HOME"; say "  삭제 완료"; else say "  취소했습니다."; fi
  else
    warn "  확인을 받을 수 없어 취소했습니다. 비대화형이면 --yes 를 쓰세요."
  fi
fi
