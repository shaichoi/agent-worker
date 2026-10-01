#!/bin/sh
# aw 제거 — 저장소에서 돌리는 aw uninstall 입니다. 설치한 aw 로 aw uninstall 을 해도 같습니다.
#
# 워커 기록(실행 중이면 멈춤), 설정 파일, aw 가 넣은 스킬, 설치한 실행 파일을 모두 지웁니다.
# 지울 것을 먼저 보여 주고, 터미널이면 한 번 묻습니다. 아니면 --yes 가 있어야 지웁니다.
# 저장소의 aw 는 남깁니다. 옵션: ./uninstall.sh --help

set -eu

SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec sh "$SRC_DIR/aw" uninstall "$@"
