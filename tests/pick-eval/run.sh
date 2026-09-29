#!/bin/sh
# aw pick 의 설명대로 Jev 가 고르는지 실제 API 로 잽니다. 네트워크와 TypeSafe 키가 필요하고, 작업마다 요청이 한 번 갑니다.
# 설명을 고친 뒤 이걸로 전후를 견주세요. tests/run-tests.sh 는 이걸 돌리지 않습니다.
# 결과는 이 컴퓨터에 어떤 CLI 가 PATH 에 있고 각 CLI 의 모델 목록(aw models)이 어떤지에 따라 달라집니다
# (없는 에이전트와 목록에 없는 모델 줄은 고르지 않음). README 의 숫자는 다섯 CLI 가 모두 있고 codex 에
# GPT-6 가 보이는 컴퓨터에서 잰 것입니다.
#
#   tests/pick-eval/run.sh [설명 파일] [작업 파일...]   기본: 권장 설명, tasks.txt 와 heldout.txt
#
# 작업 파일은 '번호|작업|정답 에이전트|받아 줄 모델(쉼표로 여럿)' 한 줄씩. 에이전트가 맞고 고른 모델이
# 받아 줄 모델 중 하나면 맞은 것입니다. 모델 확신이 낮아 기본값으로 가면 모델은 틀린 것으로 셉니다.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AW="$here/../../aw"
pick=${1:-}
[ $# -gt 0 ] && shift
if [ -z "$pick" ]; then
  pick="${TMPDIR:-/tmp}/aw-pick-eval.$$"
  trap 'rm -f "$pick"' EXIT
  AW_PICK=$pick "$AW" pick on --force < /dev/null > /dev/null 2>&1
fi
[ $# -gt 0 ] || set -- "$here/tasks.txt" "$here/heldout.txt"
for f in "$@"; do
  n=0; ok_a=0; ok_m=0
  printf '== %s\n' "$(basename "$f")"
  while IFS='|' read -r num task want_a want_m; do
    case "$num" in '#'* | '') continue ;; esac
    n=$((n + 1))
    out=$(AW_PICK=$pick "$AW" pick --fallback none --dry-run -- "$task" 2>&1)
    got_a=$(printf '%s\n' "$out" | sed -n 's/^고른 에이전트: \([^ ]*\).*/\1/p')
    got_m=$(printf '%s\n' "$out" | sed -n 's/^고른 모델    : \([^ ]*\).*/\1/p')
    [ -n "$got_a" ] || got_a='(안 띄움)'
    ma=x; mm=x
    if [ "$got_a" = "$want_a" ]; then
      ma=o; ok_a=$((ok_a + 1))
      case ",$want_m," in *",$got_m,"*) mm=o; ok_m=$((ok_m + 1)) ;; esac
    fi
    printf '%3s %s%s  %-9s %-24s %s\n' "$num" "$ma" "$mm" "$got_a" "$got_m" "$(printf '%s' "$task" | cut -c1-50)"
  done < "$f"
  printf '   에이전트 %d/%d, 에이전트와 모델 %d/%d\n\n' "$ok_a" "$n" "$ok_m" "$n"
done
