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

도구 안에 필요한 내용이 다 들어 있습니다. README 없이 `aw help` 만 봐도 쓸 수 있고,
에이전트별 호출법과 함정은 `aw help agents` 에 있습니다.


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

PATH 확인과 권한 옵션 설정까지 해주는 설치 스크립트도 있습니다
(`--no-defaults` 를 주면 권한 옵션은 켜지 않습니다).

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
| `aw defaults [--init]` | 기본 옵션 확인 / 권장값으로 켜기 |
| `aw version` | 버전 |
| `aw help [주제]` | 도움말. 주제: `agents` `defaults` `files` `limits` |

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
| `--no-defaults` | 에이전트별 기본 옵션을 붙이지 않음 |

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

## 에이전트 연동 (처음 설정)

`aw`는 에이전트를 설치해 주지 않습니다. 각 CLI를 설치·로그인한 뒤 `aw`로 감싸 쓰면 됩니다.
아래는 이 도구로 실제 돌려 본 네 가지입니다.

| | 설치 | 인증 | 프롬프트 | JSON 결과 필드 |
| --- | --- | --- | --- | --- |
| **agy** (Antigravity) | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` | `agy` 최초 1회 → 브라우저 | `-p='...'` | `response`, `status` |
| **claude** (Claude Code) | `curl -fsSL https://claude.ai/install.sh \| bash` | `claude auth login` | `-p "..."` | `result`, `is_error` |
| **devin** | 공식 설치 프로그램 | `devin auth login` | `-p "..."` (바로 뒤) | 텍스트 |
| **codex** | `npm i -g @openai/codex` | ChatGPT 계정 또는 `CODEX_API_KEY` | `codex exec "..."` 또는 stdin `-` | JSONL(`--json`) |

무인 실행에 필요한 권한 옵션은 `aw`가 **자동으로 붙입니다** (아래 "기본 옵션" 참고).

### agy — Antigravity CLI (Gemini)

```sh
curl -fsSL https://antigravity.google/cli/install.sh | bash   # ~/.local/bin/agy
agy                                                            # 최초 1회: 브라우저로 Google 로그인
agy models                                                     # gemini-3.8-flash-high 등 확인
```

설치 프로그램이 `~/.bashrc`와 `~/.bash_profile`에 PATH 줄을 덧붙입니다(zsh는 건드리지 않음).

```sh
aw run -n a1 -- agy --output-format json --model gemini-3.8-flash-high -p='테스트를 추가해줘'
aw wait a1 && aw result a1 --field response
```

**`-p` 의 함정**: `-p` 뒤에 오는 토큰이 무조건 프롬프트가 됩니다.
`agy -p --output-format json` 처럼 쓰면 `--output-format` 이 프롬프트가 되고 이렇게 실패합니다.

```
Error: -p took "--output-format" as its prompt, so the intended prompt was
left as an argument and ignored.
```

프롬프트를 `-p` 바로 뒤에 두거나 `-p='프롬프트'` 로 붙이세요. **일반 텍스트 프롬프트는
표준 입력으로 못 넣습니다** — stdin 은 `--input-format stream-json`(줄마다 NDJSON)일 때만
읽습니다. 그래서 `aw` 의 `-f` 대신 인자로 넘깁니다.

`--output-format json` 의 실제 응답:

```json
{"conversation_id":"1553b767-...","status":"SUCCESS","response":"4\n",
 "duration_seconds":1.99,"num_turns":1,
 "usage":{"input_tokens":11894,"output_tokens":161,"thinking_tokens":160,
          "cache_read_tokens":0,"total_tokens":12055}}
```

| 꺼낼 값 | 명령 |
| --- | --- |
| 응답 본문 | `aw result <이름> --field response` |
| 성공 여부 | `aw result <이름> --field status` (`SUCCESS`) |
| 이어가기용 ID | `aw result <이름> --field conversation_id` → `agy --conversation <id>` |

지원 플래그: `-p/--print/--prompt`, `--output-format text|json|stream-json`,
`--input-format text|stream-json`, `--model`, `--effort low|medium|high`,
`--dangerously-skip-permissions`, `--print-timeout`, `--json-schema`,
`--continue`, `--conversation <id>`. 종료 코드는 `0` 성공, `1` 오류, `2` 스트리밍 입력 미지원.

### claude — Claude Code

```sh
curl -fsSL https://claude.ai/install.sh | bash
claude auth login
```

```sh
aw run -n c1 -- claude -p --output-format json "테스트를 추가해줘"
aw wait c1 && aw result c1 --field result
```

계정이 여러 개면 [claude-profiles](https://github.com/shaichoi/claude-profiles)와 함께 씁니다.

```sh
aw run -n c2 --profile work-sub -- claude -p "작업"
```

### devin

```sh
devin auth status        # 로그인 확인
devin models list        # 모델 목록
```

```sh
aw run -n d1 -- devin -p "테스트를 추가해줘" --model gemini-3-8-flash-high
```

두 가지를 조심하세요.

**프롬프트는 `-p` 바로 뒤에 와야 합니다.** 사이에 다른 옵션이 끼면 이렇게 실패합니다.

```
error: the argument '--print [<PROMPT>]' cannot be used with '[PATH]...'
```

**디렉터리마다 한 번 대화형으로 실행해 신뢰 등록**을 해야 합니다. 등록 전에는
`Refusing to run in an untrusted workspace` 로 바로 실패합니다. 그 디렉터리에서
`devin` 을 한 번 직접 실행하면 됩니다.

`--model` 로 다른 모델을 쓰면 컨텍스트가 1M 이므로 한도 경고를 함께 조정하세요.

```sh
aw run -n g1 --max-input-tokens 1000000 -- devin -p "설계를 검토해줘" --model gemini-3-8-flash-high
```

### codex — OpenAI Codex CLI

```sh
npm install -g @openai/codex
codex          # 최초 1회 로그인 (또는 CODEX_API_KEY 환경변수)
```

`codex exec`가 비대화형 모드이고, **프롬프트를 stdin 으로 받을 수 있습니다**(`-`).
네 에이전트 중 유일하게 `aw`의 `-f`를 그대로 쓸 수 있어 127KB 인자 제한을 피합니다.

```sh
aw run -n x1 -- codex exec --json "테스트를 추가해줘"
aw run -n x2 -f spec.md -- codex exec --json -     # 큰 프롬프트도 문제없음
```

출력은 JSONL(줄마다 JSON 이벤트)이라 `--field` 대신 `aw result x1 | tail -1` 처럼 쓰세요.

> 이 컴퓨터에 codex 는 설치돼 있지 않아 **문서 기준으로만** 적었습니다.
> 나머지 셋은 실제로 돌려 확인했습니다.

### 워커로 쓸 수 없는 것

**GUI 기반 도구(Antigravity IDE, Cursor 등)는 안 됩니다.** VS Code 계열의 CLI 는 창을 여는
용도라 헤드리스로 돌지 않습니다. 같은 모델을 쓰고 싶으면 그 모델을 지원하는 CLI 에이전트를
쓰세요 — 예를 들어 Gemini 는 `agy` 나 `devin --model gemini-...` 로 돌립니다.

### 프롬프트가 클 때

프롬프트를 명령 인자로 넘기는 방식(`agy -p "$(cat spec.md)"`)에는 **운영체제 한계**가 있습니다.
리눅스는 인자 **하나**의 크기를 128KB(`MAX_ARG_STRLEN`, 32 × 페이지 크기)로 제한합니다.
직접 재 보면 127KB 까지는 통과하고 128KB 부터 `argument list too long` 으로 실패합니다.
이건 셸이 `aw` 를 실행하기도 전에 거부하는 것이라 `aw` 가 대신 처리해 줄 수 없습니다.

| 프롬프트 크기 | 방법 |
| --- | --- |
| ~127KB 이하 | `-- agy -p="$(cat spec.md)"` 그대로 (특수문자까지 그대로 전달됩니다) |
| 그보다 크면 | 파일을 그대로 두고 짧은 프롬프트로 가리키기: `-- agy -p='spec.md 의 지시를 따라라'` |
| 표준 입력을 받는 에이전트 | `aw run -f spec.md -- <명령>` |

큰 사양서는 파일로 두고 에이전트가 자기 도구로 읽게 하는 편이 토큰 면에서도 낫습니다.
필요한 부분만 읽기 때문입니다.

## 기본 옵션 (권한 우회)

무인 워커는 승인 프롬프트를 만나면 멈추거나 조용히 거부됩니다. 그래서 에이전트별로
"사람 없이 돌 때" 필요한 옵션을 **명령 뒤에 자동으로 붙일 수 있습니다.**

이건 권한을 올리는 일이라 `aw` 가 제멋대로 하지 않습니다. **설정 파일이 있을 때만**
적용합니다. `install.sh` 가 설치할 때 그 파일을 만들어 주므로 안내대로 설치했다면
아래 표가 바로 적용됩니다. 원하지 않으면 `./install.sh --no-defaults` 로 설치하거나
나중에 파일을 지우면 됩니다.

```sh
aw defaults              # 지금 적용 중인 것 확인
aw defaults --init       # 권장값으로 켜기
rm ~/.config/agent-worker/defaults   # 끄기
```

```sh
$ aw run -n a1 -- agy -p='리팩터링'
워커 시작: a1
  명령: agy -p=리팩터링 --dangerously-skip-permissions
  (기본 옵션이 붙었습니다: --dangerously-skip-permissions — 끄려면 --no-defaults)
```

| 명령 | 붙는 옵션 |
| --- | --- |
| `agy` | `--dangerously-skip-permissions` |
| `claude` | `--permission-mode bypassPermissions` |
| `devin` | `--permission-mode dangerous` |
| `codex` | `--sandbox workspace-write` |

- **설정 파일이 없으면 아무것도 붙지 않습니다.** 파일을 받아 바로 실행한 사람에게
  권한이 조용히 올라가는 일은 없습니다
- 붙인 내용은 **항상 화면에 찍습니다**
- 같은 옵션을 직접 지정하면 덧붙이지 않습니다 (`--permission-mode acceptEdits` 를 주면 그대로)
- 한 번만 끄려면 `--no-defaults`, 그 셸에서 끄려면 `AW_NO_DEFAULTS=1`
- 표를 바꾸거나 새 에이전트를 추가하려면 `~/.config/agent-worker/defaults` 에
  `명령이름 옵션...` 한 줄씩. `aw defaults --init --force` 로 권장값으로 되돌립니다

```
myagent --yolo --quiet
agy --dangerously-skip-permissions --effort high
```

**이게 무슨 뜻인지는 분명히 알고 쓰세요.** 권한 우회는 그 에이전트가 승인 없이 파일을 고치고
셸 명령을 실행한다는 뜻입니다. 사람이 안 보는 워커라서 켜는 것이므로, 중요한 작업 트리에서는
`-w` 로 worktree 를 떼어 놓고 돌리길 권합니다.

```sh
aw run -n risky -w feat/experiment -- agy -p='대규모 리팩터링'
```

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
| `AW_DEFAULTS` | `~/.config/agent-worker/defaults` | 에이전트별 기본 옵션 파일 |
| `AW_NO_DEFAULTS` | (없음) | `1` 이면 기본 옵션을 붙이지 않음 |
| `AW_PREFIX` | `~/.local/bin` | `install.sh` / `uninstall.sh` 의 설치 위치 |

테스트나 임시 실험은 `AW_HOME` 만 바꾸면 평소 기록과 완전히 분리됩니다.

```sh
AW_HOME=/tmp/aw-test aw run -- echo 시험
```

## 알아둘 점

**에이전트마다 고정 비용이 다릅니다.** 같은 "2+2" 질문으로 실측하면 Claude Code 는
약 32K 토큰($0.11), Antigravity CLI(Gemini 3.8 Flash)는 약 12K 토큰이었습니다.
가벼운 작업을 많이 돌릴수록 이 차이가 커집니다.

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

도움말과 코드가 어긋나지 않는지도 검사합니다(주요 항목이 개요에 들어 있는지,
개요가 60줄을 넘지 않는지, 모든 주제가 동작하는지).

임시 `AW_HOME`에서 에이전트 없이 평범한 명령으로만 돌립니다. 수명 주기, 실패·중단,
표준 입력, 인자·환경변수 보존, JSON 필드 추출, 이름 검증(경로 탈출 차단),
부모 셸이 죽어도 살아남는지, worktree 생성·정리, bash/zsh에서의 호출까지 확인합니다.
