# agent-worker (`aw`)

아무 CLI 명령이나 백그라운드 워커로 돌리고, 상태·출력·종료 코드를 추적하는 러너입니다.
에이전트 종류를 가리지 않습니다 — `claude`, `codex`, `aider`, 빌드 스크립트가 전부 같은 방식입니다.

```
$ aw run -n refactor -- claude -p --output-format json "이 모듈 정리해줘"
워커 시작: refactor
  디렉터리: /home/me/proj
  명령: claude -p --output-format json 이 모듈 정리해줘
  보기: aw logs refactor -f    기다리기: aw wait refactor    결과: aw result refactor

$ aw list
이름               상태     코드  경과     명령
refactor           running  -     42s      claude -p --output-format json 이 모듈 정리해줘

$ aw wait refactor && aw result refactor --field result
```

## 빠른 시작

```sh
aw run -n job -- claude -p --output-format json "이 저장소에 테스트를 추가해줘"
aw logs job -f                      # 진행 보기 (Ctrl-C 로 빠져나와도 워커는 계속)
aw wait job && aw result job --field result
aw rm job
```

## 왜 에이전트별 도구가 아닌가

에이전트마다 다른 건 세 가지뿐입니다 — 프롬프트를 어떻게 넣는지, 인증을 어떻게 잡는지,
결과가 어떤 형식인지. 나머지(백그라운드로 떼어내기, 출력 보관, 종료 코드, 작업 공간 격리)는
전부 똑같습니다. 그래서 `aw`는 명령을 **그대로** 받고 그 세 가지만 거들어 줍니다.

- 프롬프트 → `--stdin-file` 로 표준 입력에 물림 (기본 표준 입력은 `/dev/null`이라 멈추지 않음)
- 인증 → `--env KEY=VAL` 통과. Claude Code 면 `--profile` 로 `CLAUDE_CONFIG_DIR` 지정
- 결과 → 그냥 stdout 파일. JSON이면 `--field` 로 값 하나 꺼내기

## 요구사항

- POSIX 셸과 표준 도구 (`sed`, `awk`, `find`, `git`은 worktree 쓸 때만)
- `python3`, `jq` 필요 없음

## 설치

```sh
curl -fsSL https://raw.githubusercontent.com/shaichoi/agent-worker/main/aw -o ~/.local/bin/aw && chmod +x ~/.local/bin/aw
```

실행 파일 하나라서 이게 전부입니다. 셸 설정을 건드리지 않고, `source` 도 필요 없습니다.

> 저장소가 **Private** 이면 위 raw URL 은 인증 없이 열리지 않습니다(404).
> 그때는 아래 `git clone` 을 쓰거나, 이미 설치된 곳에서 파일 하나만 옮기세요.
> `scp ~/.local/bin/aw 서버:~/.local/bin/aw`

PATH 확인까지 해주는 설치 스크립트도 있습니다.

```sh
git clone git@github.com:shaichoi/agent-worker.git
cd agent-worker
./install.sh
```

## 명령

| 명령 | 하는 일 |
| --- | --- |
| `aw run [옵션] -- <명령...>` | 워커를 백그라운드로 띄움 |
| `aw list [--json]` | 목록과 상태 |
| `aw status <이름>` | 하나의 상세 |
| `aw logs <이름> [-f] [-n N]` | 표준 출력 (`-f` 는 따라가기) |
| `aw errs <이름>` | 표준 오류 |
| `aw result <이름> [--field K]` | 출력 전문, 또는 JSON 필드 하나 |
| `aw wait <이름...> [--timeout N]` | 끝날 때까지 대기 (실패면 0이 아닌 코드) |
| `aw stop <이름...>` | 프로세스 그룹째 종료 |
| `aw rm <이름...>` / `aw clean [--all]` | 기록 정리 (worktree 도 함께) |
| `aw contexts` | 에이전트별 컨텍스트 한도 표 |
| `aw version` / `aw help` | 버전 / 도움말 |

`aw ls` 는 `aw list` 의 별칭입니다. `aw logs` 의 `-n` 기본값은 40줄입니다.

`aw wait` 의 종료 코드는 스크립트에서 바로 쓸 수 있습니다.

| 코드 | 뜻 |
| --- | --- |
| `0` | 기다린 워커가 전부 정상 종료 |
| `1` | 하나 이상 실패했거나 프로세스가 사라짐(`lost`) |
| `2` | `--timeout` 으로 지정한 시간을 넘김 |

```sh
if aw wait build test; then echo "둘 다 성공"; else echo "실패한 워커 있음"; aw list; fi
```

### `run` 옵션

| 옵션 | 설명 |
| --- | --- |
| `-n, --name <이름>` | 워커 이름 (기본: 명령 이름 + 번호) |
| `-d, --dir <경로>` | 실행 디렉터리 (기본: 현재) |
| `-w, --worktree <브랜치>` | 새 git worktree를 만들어 거기서 실행 |
| `-f, --stdin-file <파일>` | 표준 입력으로 물릴 파일 |
| `-e, --env KEY=VAL` | 환경변수 (여러 번 가능) |
| `--tag <문자열>` | 분류용 꼬리표 |
| `--profile <이름>` | `CLAUDE_CONFIG_DIR`을 그 프로필로 (Claude Code 편의) |
| `--max-input-tokens N` | 컨텍스트 경고 기준을 직접 지정 (`0`이면 끄기) |

## 쓰는 법

긴 작업을 던져 놓고 다른 일 하기:

```sh
aw run -n bigjob -f task.md -- claude -p --output-format json
aw logs bigjob -f
```

여러 개를 병렬로 돌리고 전부 기다리기:

```sh
for m in auth billing search; do
  aw run -n "test-$m" -- sh -c "npm test -- $m"
done
aw wait test-auth test-billing test-search
aw list
```

서로 파일을 건드릴 위험이 있으면 worktree로 떼어 놓기:

```sh
aw run -n featA -w feat/a -- claude -p "A 기능 구현"
aw run -n featB -w feat/b -- claude -p "B 기능 구현"
```

각 워커는 `<저장소>/.aw-worktrees/<이름>`에서 새 브랜치로 돌고, `aw rm`이 worktree까지 정리합니다.
`aw`가 만든 worktree만 지우고 사용자가 만든 것은 건드리지 않습니다.

### 에이전트별 호출 예시

`aw`는 명령을 그대로 넘기므로 각 에이전트의 인자 규칙을 그대로 따릅니다.

```sh
# Claude Code — 결과를 JSON 으로 받아 필드만 뽑기
aw run -n c1 -- claude -p --output-format json "테스트를 추가해줘"
aw result c1 --field result

# Devin — 프롬프트는 -p 바로 뒤에 와야 합니다.
# -p 와 프롬프트 사이에 다른 옵션이 끼면
# "the argument '--print' cannot be used with '[PATH]...'" 로 실패합니다.
aw run -n d1 -- devin -p "테스트를 추가해줘" --permission-mode accept-edits

# Devin 으로 다른 모델 쓰기 (모델 목록은 devin models list)
aw run -n g1 --max-input-tokens 1000000 -- devin -p "설계를 검토해줘" --model gemini-3-8-flash-high

# Antigravity CLI (agy) — Gemini 계열. 헤드리스 지원이 가장 정돈돼 있습니다.
aw run -n a1 -- agy -p "테스트를 추가해줘" --model gemini-3.8-flash-high --output-format json
aw result a1 --field response

# 사람이 없는 워커라면 승인 대기로 멈추지 않게 권한 모드를 정해 주세요.
aw run -n a2 -- agy -p "리팩터링" --dangerously-skip-permissions --print-timeout 15m
```

`agy` 는 `-p/--print/--prompt` 로 프롬프트를 받고 `--output-format text|json|stream-json`,
`--model`, `--effort`, `--continue`, `--conversation <id>`, `--json-schema` 를 지원합니다.
종료 코드는 `0` 성공, `1` 오류, `2` 스트리밍 입력 미지원입니다.

Devin은 디렉터리마다 한 번 대화형으로 실행해 신뢰 등록을 해야 합니다.
등록 전에는 `Refusing to run in an untrusted workspace` 로 바로 실패합니다.

**GUI 기반 도구(Antigravity IDE, Cursor 등)는 워커로 쓸 수 없습니다.** VS Code 계열의
CLI는 창을 여는 용도라 헤드리스로 돌지 않습니다. 같은 모델을 쓰고 싶으면 그 모델을
지원하는 CLI 에이전트를 쓰세요(예: Gemini 계열은 위처럼 `devin --model`).

Claude Code 계정을 나눠 쓰는 경우 ([claude-profiles](https://github.com/shaichoi/claude-profiles)와 함께):

```sh
aw run -n job1 --profile work-sub -- claude -p "작업"
```

### 프롬프트가 클 때

프롬프트를 명령 인자로 넘기는 방식(`agy -p "$(cat spec.md)"`)에는 **운영체제 한계**가 있습니다.
리눅스는 인자 **하나**의 크기를 128KB(`MAX_ARG_STRLEN`, 32 × 페이지 크기)로 제한합니다.
직접 재 보면 127KB 까지는 통과하고 128KB 부터 `argument list too long` 으로 실패합니다.
이건 셸이 `aw` 를 실행하기도 전에 거부하는 것이라 `aw` 가 대신 처리해 줄 수 없습니다.

| 프롬프트 크기 | 방법 |
| --- | --- |
| ~127KB 이하 | `-- agy -p "$(cat spec.md)"` 그대로 (특수문자까지 그대로 전달됩니다) |
| 그보다 크면 | 파일을 그대로 두고 짧은 프롬프트로 가리키기: `-- agy -p "spec.md 의 지시를 따라라"` |
| 표준 입력을 받는 에이전트 | `aw run -f spec.md -- <명령>` |

큰 사양서는 파일로 두고 에이전트가 자기 도구로 읽게 하는 편이 토큰 면에서도 낫습니다.
필요한 부분만 읽기 때문입니다.

## 컨텍스트 한도 경고

`--stdin-file`로 넣는 입력이 에이전트의 컨텍스트 창에 비해 너무 크면 실행 전에 알려줍니다.
막지는 않고 경고만 합니다.

```
$ aw run -f huge-spec.md -- devin -p
경고: 입력이 약 740000 토큰으로 devin 의 컨텍스트 한도 262000 에 가깝습니다.
  (바이트 기준 어림값입니다. 에이전트가 읽을 저장소 파일은 포함되지 않았습니다.)
  나눠서 넣거나 --max-input-tokens 로 한도를 조정하세요.
```

기본 표는 `aw contexts`로 봅니다.

| 명령 | 토큰 | 근거 |
| --- | --- | --- |
| `devin` | 262,000 | Devin 자체 모델 SWE-2 / SWE-1.7 이 262K (`devin models list` 확인) |
| `claude` | 1,000,000 | Claude Opus 5 (`claude -p --output-format json` 의 `contextWindow`) |
| `agy` | 1,000,000 | Antigravity CLI 기본 Gemini 계열 |
| `codex` | 400,000 | 참고값 |
| `aider` | 200,000 | 참고값 |

**Devin은 `--model`로 다른 모델을 고를 수 있고 그때는 1M입니다** (Claude Opus 5, Sonnet 5,
GPT-5.6, Gemini 3.8 Flash 모두 1M). 그런 경우엔 `--max-input-tokens 1000000`으로 덮어쓰세요.

```sh
aw run --max-input-tokens 1000000 -- devin -p "..." --model gemini-3-8-flash-high
```

값을 바꾸려면 `~/.config/agent-worker/contexts`에 `명령이름 토큰수`를 적습니다.
같은 이름이 있으면 나중 줄이 이깁니다.

```
devin 1000000
mytool 128000
```

두 가지는 분명히 해둡니다. **토큰 수는 바이트 기준 어림값입니다** — ASCII는 4바이트/토큰,
한글 같은 비ASCII는 2바이트/토큰으로 잡아 안전한 쪽으로 계산합니다. 정확한 토크나이저가
아닙니다. 그리고 **이 검사는 입력 파일만 봅니다** — 에이전트가 저장소에서 읽어 들이는 파일이
보통 더 큰 비중이라, 경고가 없다고 안심할 일은 아닙니다.

## 워커 기록

`~/.local/share/agent-worker/workers/<이름>/`에 남습니다. `AW_HOME`으로 바꿀 수 있습니다.

| 파일 | 내용 |
| --- | --- |
| `meta` | 이름, 디렉터리, 시작 시각, worktree, 꼬리표 |
| `cmd` | 실행한 인자 (한 줄에 하나) |
| `out` / `err` | 표준 출력 / 표준 오류 |
| `exit` | 종료 코드 (생기면 끝난 것) |
| `input_tokens_est` / `context_limit` | 입력 크기 어림값과 적용된 한도 (meta 안) |
| `run.sh` / `launch.sh` | 실제로 돌린 스크립트 (그대로 다시 실행 가능) |

상태는 `running`(pid 살아 있음), `done`(코드 0), `failed`(0 아님), `stopped`(`aw stop`),
`lost`(종료 코드 없이 프로세스가 사라짐)입니다.

## 환경변수

| 변수 | 기본값 | 쓰임 |
| --- | --- | --- |
| `AW_HOME` | `~/.local/share/agent-worker` | 워커 기록 위치 |
| `AW_CONFIG` | `~/.config/agent-worker/contexts` | 컨텍스트 한도 설정 파일 |
| `AW_PREFIX` | `~/.local/bin` | `install.sh` / `uninstall.sh` 의 설치 위치 |

테스트나 임시 실험은 `AW_HOME` 만 바꾸면 평소 기록과 완전히 분리됩니다.

```sh
AW_HOME=/tmp/aw-test aw run -- echo 시험
```

## 알아둘 점

**에이전트 워커는 고정 비용이 있습니다.** Claude Code로 측정해 보면 "2+3은?" 한 줄에도
시스템 프롬프트와 컨텍스트 때문에 3만 토큰 가까이 듭니다. 워커는 **덩어리 작업**에 쓰는 게 맞고,
잘게 쪼개 많이 띄우는 건 오히려 비쌉니다. 비용은 `aw result <이름> | grep total_cost_usd`로
확인할 수 있습니다(Claude Code의 `--output-format json` 기준).

**승인 프롬프트가 필요한 작업은 멈춰 있을 수 있습니다.** 비대화형으로 도구를 쓰는 에이전트는
권한을 물어볼 자리가 없습니다. `claude`라면 `--permission-mode`를 함께 넘기세요. 상태가
오래 `running`이면 `aw logs`와 `aw errs`를 먼저 보세요.

**`stop`은 프로세스 그룹을 종료합니다.** 에이전트가 띄운 하위 프로세스까지 함께 정리됩니다.

**출력은 파일에 그대로 쌓입니다.** 매우 긴 작업이면 `out` 파일이 커질 수 있으니
`aw clean`으로 주기적으로 정리하세요.

## 제거

```sh
./uninstall.sh
```

실행 파일만 지우고 워커 기록은 남깁니다. 기록까지 지우려면 `--purge`를 주세요
(무엇이 지워지는지 먼저 보여주고 `yes` 입력을 받습니다).

## 검증

```sh
./tests/run-tests.sh
```

임시 `AW_HOME`에서 에이전트 없이 평범한 명령으로만 돌립니다. 수명 주기, 실패·중단,
표준 입력, 인자·환경변수 보존, JSON 필드 추출, 이름 검증(경로 탈출 차단),
부모 셸이 죽어도 살아남는지, worktree 생성·정리, bash/zsh에서의 호출까지 확인합니다.
