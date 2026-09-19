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

Claude Code 계정을 나눠 쓰는 경우 ([claude-profiles](https://github.com/shaichoi/claude-profiles)와 함께):

```sh
aw run -n job1 --profile work-sub -- claude -p "작업"
```

## 워커 기록

`~/.local/share/agent-worker/workers/<이름>/`에 남습니다. `AW_HOME`으로 바꿀 수 있습니다.

| 파일 | 내용 |
| --- | --- |
| `meta` | 이름, 디렉터리, 시작 시각, worktree, 꼬리표 |
| `cmd` | 실행한 인자 (한 줄에 하나) |
| `out` / `err` | 표준 출력 / 표준 오류 |
| `exit` | 종료 코드 (생기면 끝난 것) |
| `run.sh` / `launch.sh` | 실제로 돌린 스크립트 (그대로 다시 실행 가능) |

상태는 `running`(pid 살아 있음), `done`(코드 0), `failed`(0 아님), `stopped`(`aw stop`),
`lost`(종료 코드 없이 프로세스가 사라짐)입니다.

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
