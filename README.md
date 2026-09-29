# agent-worker (`aw`)

아무 CLI 명령이나 백그라운드 워커로 돌리고, 상태·출력·종료 코드를 추적하는 러너입니다.
에이전트 종류를 가리지 않습니다 — `claude`, `codex`, `aider`, 빌드 스크립트가 전부 같은 방식입니다.

```
$ aw run -n refactor -- claude -p --output-format stream-json --verbose "이 모듈 정리해줘"
워커 시작: refactor
  디렉터리: /home/me/proj
  명령: claude -p --output-format stream-json --verbose 이 모듈 정리해줘
  보기: aw logs refactor -f    기다리기: aw wait refactor    결과: aw result refactor

$ aw list
이름               상태     코드  경과     명령
refactor           running  -     42s      claude -p --output-format stream-json --verbose 이 모듈…

$ aw wait refactor && aw result refactor --field result
```

## 빠른 시작

도구 안에 필요한 내용이 다 들어 있습니다. README 없이 `aw help` 만 봐도 쓸 수 있고,
에이전트별 호출법과 주의할 점은 `aw help agents` 에 있습니다.


```sh
aw run -n job -- claude -p --output-format stream-json --verbose "이 저장소에 테스트를 추가해줘"
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
curl -fsSL https://raw.githubusercontent.com/shaichoi/agent-worker/main/install.sh | sh
```

실행 파일을 `~/.local/bin` 에 놓고, 무인 실행용 [기본 옵션](#기본-옵션-권한-우회-모델)(권한 우회, 기본 모델)을 켜고, 에이전트들이 `aw` 를 쓸 수 있게 하는
[스킬](#에이전트가-aw-를-쓰게-하기-스킬)을 넣을지 에이전트마다 묻고, PATH 를 확인합니다. 셸 설정은 건드리지 않습니다.
다시 돌리면 최신으로 덮어씁니다(기본 옵션 파일은 그대로 둡니다. 새로 생긴 권장값은 `aw defaults` 가 알려 줍니다).
설치한 뒤 무엇이 갖춰졌는지는 `aw setup` 으로 점검합니다.

| 옵션 | 스킬 |
| --- | --- |
| (없음) | 터미널이면 찾은 에이전트마다 묻고 넣음 (기본 아니오). 터미널이 없으면(스크립트, CI) 새로 넣지 않음 |
| `--skill` | 찾은 에이전트 전부에 묻지 않고 넣음 |
| `--skill=claude,agy` | 고른 에이전트에만 넣음 |
| `--no-skill` | 아예 건드리지 않음 |

이미 넣어 둔 스킬은 `--no-skill` 이 아니면 묻지 않고 새 버전으로 바꿉니다(전에 고른 것이라서).
`curl … | sh` 로 받아도 터미널(`/dev/tty`)로 묻습니다. 옵션은 `sh -s --` 뒤에 줍니다.

```sh
curl -fsSL https://raw.githubusercontent.com/shaichoi/agent-worker/main/install.sh | sh -s -- --skill=claude,codex
```

`--no-defaults` 를 주면 기본 옵션은, `--no-brief` 를 주면 [워커 지시문](#워커-지시문-brief)은 켜지 않습니다.

실행 파일 하나만 원하면 이것으로 충분합니다. `source` 도 필요 없습니다.

```sh
curl -fsSL https://raw.githubusercontent.com/shaichoi/agent-worker/main/aw -o ~/.local/bin/aw && chmod +x ~/.local/bin/aw
```

> 저장소가 **Private** 이면 위 raw URL 은 인증 없이 열리지 않습니다(404).
> 그때는 아래 `git clone` 을 쓰거나, 이미 설치된 곳에서 파일 하나만 옮기세요.
> `scp ~/.local/bin/aw 서버:~/.local/bin/aw`

```sh
git clone git@github.com:shaichoi/agent-worker.git
cd agent-worker
./install.sh            # 설치 옵션: ./install.sh --help
```

## 명령

| 명령 | 하는 일 |
| --- | --- |
| `aw run [옵션] -- <명령...>` | 워커를 백그라운드로 띄움 |
| `aw list [--json]` | 목록과 상태 |
| `aw status <이름>` | 하나의 상세 |
| `aw logs <이름> [-f] [-n N]` | 표준 출력 (`-f` 는 따라가기) |
| `aw errs <이름>` | 표준 오류 |
| `aw peek [이름...]` | [진행 상황](#진행-상황-보기): 지금 도는 명령, 최근 활동, worktree 변경 |
| `aw watch [이름...] [-i 초]` | `peek` 을 몇 초마다 다시 그림 (Ctrl-C 해도 워커는 계속) |
| `aw result <이름> [--field K]` | 출력 전문, 또는 JSON 필드 하나 |
| `aw resume <이름> -- '프롬프트'` | 그 워커의 대화를 이어서 새 워커로 |
| `aw wait <이름...> [--timeout N] [--idle N]` | 끝날 때까지 대기 (실패면 0이 아닌 코드). `--idle` 은 [조용함](#조용할-때-생각-중인가-멈췄나) 알림 |
| `aw stop <이름...>` | 프로세스 그룹째 종료 |
| `aw rm <이름...>` / `aw clean [--all]` | 기록 정리 (worktree 도 함께) |
| `aw contexts` | 에이전트별 컨텍스트 한도 표 |
| `aw defaults [get\|set\|unset]` | [기본 옵션](#기본-옵션-권한-우회-모델)(권한, 모델) 보기 / 바꾸기. `--init` 은 권장값으로 켜기 |
| `aw models [에이전트] [--refresh]` | 설치된 CLI 의 [모델 목록](#모델-목록-aw-models). 기본 옵션의 모델이 목록에 없으면 CLI 기본으로 |
| `aw brief [--init]` | [워커 지시문](#워커-지시문-brief) 확인 / 권장값으로 켜기 |
| `aw pick [on\|off\|key]` / `aw pick -- '작업'` | (실험용) Jev 가 [작업에 맞는 에이전트·모델을 골라](#에이전트-고르기-aw-pick-실험용) 워커를 띄움 |
| `aw skill [install\|remove] [에이전트...]` | 에이전트용 [스킬](#에이전트가-aw-를-쓰게-하기-스킬) 상태 / 넣기 / 빼기 |
| `aw setup` | 설치 점검 (터미널에서는 빠진 것마다 물어봄) |
| `aw version` | 버전 |
| `aw help [주제]` | 도움말. 주제: `agents` `defaults` `files` `limits` `peek` `brief` `pick` `models` |

`aw ls` 는 `aw list` 의 별칭입니다. `aw logs` 의 `-n` 기본값은 40줄입니다.

`aw wait` 의 종료 코드는 스크립트에서 바로 쓸 수 있습니다.

| 코드 | 뜻 |
| --- | --- |
| `0` | 기다린 워커가 전부 정상 종료 |
| `1` | 하나 이상 실패했거나 프로세스가 사라짐(`lost`) |
| `2` | `--timeout` 으로 지정한 시간을 넘김 |
| `3` | `--idle` 로 지정한 시간 동안 아무 신호가 없음 (워커는 끊지 않음) |

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
| `--no-brief` | 워커 지시문을 붙이지 않음 |

## 쓰는 법

긴 작업을 던져 놓고 다른 일 하기:

```sh
aw run -n bigjob -f task.md -- claude -p --output-format stream-json --verbose
aw watch bigjob          # 지금 무엇을 하는지 (날것의 출력은 aw logs bigjob -f)
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

## 진행 상황 보기

`aw peek <이름>` 은 지금 무엇을 하는지 한 번 보여 주고, `aw watch <이름>` 은 그걸 몇 초마다 다시 그립니다
(Ctrl-C 로 멈춰도 워커는 계속 돕니다. 워커가 끝나면 스스로 멈춥니다). 이름을 빼면 실행 중인 워커 전부를 짧게 보여 줍니다.

```
$ aw peek review
review  running  3m12s  claude
  지금 실행 중: npm test -- auth   (41s)
  마지막 활동 : 5s 전
  최근 활동 (claude 대화 기록에서)
    Read     src/auth/login.ts
    Bash     npm test -- auth
    말       테스트 3개가 실패합니다. 원인을 보겠습니다.
  worktree    : 파일 4개 바뀜 (+120 -35, 새 파일 1개)   ~/proj/.aw-worktrees/review
```

| 항목 | 어디서 |
| --- | --- |
| 지금 실행 중 | 워커가 띄운 하위 프로세스 중 가장 최근 것. 에이전트는 명령을 새 세션이나 샌드박스로 떼어 띄워서(실측: claude, codex) 프로세스 그룹이 아니라 부모-자식 관계로 따라갑니다. MCP 서버나 kiro-cli 의 `acp-server.js` 같은 상주 도우미는 뺍니다. Linux 와 macOS(26.5) 에서 확인했습니다 |
| 마지막 활동 | 아래 신호 중 가장 최근 것과 그 출처: 출력, claude 대화 기록, codex 세션 파일, 새로 뜬 하위 명령, 작업 폴더에서 바뀐 파일 |
| 최근 활동 | 에이전트 출력을 읽을 수 있게 풉니다: claude `stream-json`, codex `--json`, agy·kiro-cli `--output-format stream-json`. agy·kiro-cli 는 몇 글자씩 조각으로 오는 답을 이어 붙여 말 한 줄로 보여 줍니다. 모르는 형식(텍스트, 빌드 로그)은 마지막 줄들을 그대로 보여 줍니다 |
| 예상 소요 | [지시문](#워커-지시문-brief)대로 에이전트가 적은 예상 소요 시간을 경과와 견줌. 넘기면 "예상보다 N 더 걸리는 중" |
| 생각 중 | claude(`stream-json`)는 지금까지 생각한 토큰 수, codex 는 추론 단계 수, kiro-cli 는 지금 이어지는 생각 글의 글자 수. 생각 내용이 숨겨져 있어도 양은 보입니다 |
| 조용함 | 출력, 새 명령, 파일 변경, 생각 신호가 모두 멈춘 지 `AW_QUIET` 초(기본 300)가 넘으면 알립니다 |
| worktree | `-w` 로 띄웠으면 지금까지 바뀐 파일 수 |
| 답 | 끝난 워커면 JSON 결과의 최종 답 한 줄. kiro-cli 는 마지막 말 (`finalText` 는 그 턴의 말을 진행 줄까지 구분 없이 이어 붙여서) |
| 주의 | kiro-cli 가 모델 거절로 도중에 멈췄으면 사유와 함께 (코드 0 이라 따로 알림) |

**claude 를 `--output-format json` 으로 띄워도 보입니다.** 이 형식은 끝날 때 한 번에 나와서 도중엔 출력이
비어 있습니다. 대신 claude 는 도는 동안 `~/.claude/sessions/<pid>.json` 에 세션 ID 를 적고, 대화 기록
(`~/.claude/projects/…/<세션>.jsonl`)을 실시간으로 씁니다(실측, 2.1.280). `aw` 는 워커의 pid 로 그 기록을
찾으므로, 같은 폴더에서 claude 가 여럿 돌아도 헷갈리지 않습니다. `--profile` 로 띄웠으면 그 프로필의 기록을 봅니다.

devin 은 텍스트를 줄바꿈 없이 한 줄로 길게 쌓습니다(실측). 그래서 텍스트 출력은 긴 줄의 **끝**(가장 최근)을 보여 줍니다.
도중에 아무것도 안 내놓는 동안에는 지금 도는 명령만 보입니다.

`aw peek` 은 한 번 보고 돌아오므로 에이전트도 씁니다(스킬에 적혀 있음). `aw watch` 는 끝날 때까지
돌아오지 않아 사람이 보는 용입니다.

### 조용할 때: 생각 중인가, 멈췄나

에이전트는 도구 없이 오래 생각하는 동안 아무것도 안 내놓기도 합니다. 같은 문제(머리로 계산)를 주고
생각하는 동안 밖에서 무엇이 보이는지 재 봤습니다.

| 에이전트 | 걸린 시간 | 생각하는 동안 보이는 것 |
| --- | --- | --- |
| claude (`stream-json`) | 90초 | 몇 초마다 `thinking_tokens` 줄 (지금까지 생각한 토큰 수) |
| codex | 50초 | 출력은 조용하지만 자기 세션 파일(`~/.codex/sessions/…`)에 추론 단계가 10~15초마다 |
| agy | 2분 47초 | 없음 (출력도 대화 저장 파일도 멈춤) |
| kiro-cli (v3 엔진) | 16초 | 생각 내용 조각(`agent_thought_chunk`)이 2~4초마다 출력에 |
| devin | 5분 56초 | 없음 (출력 0 바이트, 로그는 15초마다 도는 주기 작업뿐) |

devin 은 6분 가까이 아무것도 안 내놓다가 정답을 냈습니다. **조용하다고 멈춘 건 아닙니다.** devin 과 agy 는
밖에서 생각 중인지 멈췄는지 알 방법이 없습니다(읽기·쓰기 바이트나 CPU 도 주기 작업 때문에 늘 조금씩 움직여
가려낼 수 없었습니다). 그래서 `aw` 는 끊지 않고 알리기만 합니다.

```sh
aw wait job --idle 600          # 10분 동안 아무 신호가 없으면 코드 3 으로 돌아옴 (워커는 계속)
aw peek job                     # 무엇이 멈췄는지, 에이전트별로 조용한 게 정상인지 안내
AW_QUIET=120 aw peek            # 조용함 알림 기준을 2분으로
```

```
lv-d  running  6m12s  devin
  지금 실행 중: (하위 명령 없음. 에이전트가 생각하거나 답을 쓰는 중)
  마지막 활동 : 없음 (출력도 기록도 아직 없음)
  조용함      : 6m12s째 신호가 없습니다 (출력, 새 명령, 파일 변경, 생각)
                이 에이전트는 생각하는 동안 아무것도 내지 않아, 멈췄는지 밖에서는 알 수 없습니다.
                (실측: devin 6분, agy 3분 조용하다가 정답)
                더 기다리거나, 멈추려면 aw stop lv-d
```

스크립트에서는 코드 3 을 받아 멈추거나(`aw stop`), 더 기다리거나, `aw resume` 으로 재촉하는 걸 직접 정하면 됩니다.

## 에이전트 연동 (처음 설정)

`aw`는 에이전트를 설치해 주지 않습니다. 각 CLI를 설치·로그인한 뒤 `aw`로 감싸 쓰면 됩니다.
아래는 이 도구로 실제 돌려 본 다섯 가지입니다.

| | 설치 | 인증 | 프롬프트 | JSON 결과 필드 |
| --- | --- | --- | --- | --- |
| **agy** (Antigravity) | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` | `agy` 최초 1회 → 브라우저 | `-p='...'` | `response`, `status` |
| **claude** (Claude Code) | `curl -fsSL https://claude.ai/install.sh \| bash` | `claude auth login` | `-p "..."` | `result`, `is_error` |
| **devin** | 공식 설치 프로그램 | `devin auth login` | `-p "..."` (바로 뒤) | 텍스트 |
| **codex** | `npm i -g @openai/codex` | ChatGPT 계정 또는 `CODEX_API_KEY` | `codex exec "..."` 또는 stdin `-` | JSONL(`--json`) |
| **kiro-cli** (Kiro) | Kiro 공식 설치 안내 (kiro.dev) | `kiro-cli login` | `kiro-cli chat "..."` (맨 끝) 또는 stdin | `finalText`, `status` (`stream-json`) |

무인 실행에 필요한 권한 옵션과 기본 모델(agy `gemini-3.8-flash`, devin `swe-2-max`, kiro-cli `claude-opus-5.5`)은
`aw`가 **자동으로 붙입니다** ([기본 옵션](#기본-옵션-권한-우회-모델) 참고).

### agy — Antigravity CLI (Gemini)

```sh
curl -fsSL https://antigravity.google/cli/install.sh | bash   # ~/.local/bin/agy
agy                                                            # 최초 1회: 브라우저로 Google 로그인
agy models                                                     # gemini-3.8-flash-high 등 확인
```

설치 프로그램이 `~/.bashrc`와 `~/.bash_profile`에 PATH 줄을 덧붙입니다(zsh는 건드리지 않음).

```sh
aw run -n a1 -- agy --output-format stream-json -p='테스트를 추가해줘'
aw wait a1 && aw result a1 --field response
```

**모델**: `--model` 을 안 주면 기본 옵션이 `--model gemini-3.8-flash --effort high` 를 붙입니다.
수준을 뺀 이름(`gemini-3.8-flash`)은 `--effort` 가 있어야 하고, `gemini-3.8-flash-high` 에
`--effort low` 를 같이 주면 부딪쳐 실패합니다(실측). 그래서 `--model` 이나 `--effort` 중 하나라도
직접 주면 aw 는 모델 줄을 통째로 붙이지 않습니다. 기본값을 바꾸려면
`aw defaults set agy --model gemini-3.1-pro-high` 처럼 합니다.

**`-p` 를 쓸 때 주의할 점**: `-p` 뒤에 오는 토큰이 무조건 프롬프트가 됩니다.
`agy -p --output-format json` 처럼 쓰면 `--output-format` 이 프롬프트가 되고 이렇게 실패합니다.

```
Error: -p took "--output-format" as its prompt, so the intended prompt was
left as an argument and ignored.
```

프롬프트를 `-p` 바로 뒤에 두거나 `-p='프롬프트'` 로 붙이세요.

**`-p` 를 빼면 표준 입력을 읽습니다.** 그래서 `aw` 의 `-f` 를 그대로 쓸 수 있고, 인자
크기 제한(127KB)도 피합니다. 379KB 파일로 확인했습니다.

```sh
aw run -n a2 -f spec.md -- agy --output-format stream-json
```

`-p` 와 표준 입력을 같이 주면 `-p` 가 이기고 표준 입력은 무시됩니다.

**`--output-format stream-json` 을 권합니다.** 도중 사건(도구 호출, 단계)이 한 줄씩 쌓여 `aw peek` 과
`aw logs -f` 로 진행이 보입니다. 마지막 줄이 아래 `json` 결과와 같은 내용이라 `--field` 는 똑같이 됩니다.
`--output-format json` 은 끝날 때 한 번에 나와서 도중엔 출력이 없습니다. 그 결과의 실제 모양:

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
aw run -n c1 -- claude -p --output-format stream-json --verbose "테스트를 추가해줘"
aw wait c1 && aw result c1 --field result      # 성공 여부: --field is_error (true/false)
```

`stream-json` 은 `-p` 와 같이 쓸 때 `--verbose` 가 필요합니다. 도중 사건이 쌓여 `aw peek`, `aw logs -f` 로
진행이 보이고, 끝난 뒤 `--field` 는 `json` 과 똑같이 됩니다. `--output-format json` 도 됩니다. 끝날 때까지
출력이 비지만 `aw peek` 은 claude 의 대화 기록에서 진행을 읽습니다.

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
aw run -n d1 -- devin -p "테스트를 추가해줘"
```

**모델**: `--model` 을 안 주면 기본 옵션이 `--model swe-2-max` 를 붙입니다. SWE-2 는 `swe-2-medium`,
`swe-2-high`, `swe-2-max` 가 있고, `swe-2` 만 주면 high 로 돕니다(실측: devin 세션 기록). 기본값을 바꾸려면
`aw defaults set devin --model swe-2-high` 처럼 합니다.

세 가지를 조심하세요.

**프롬프트는 `-p` 바로 뒤에 와야 합니다.** 사이에 다른 옵션이 끼면 이렇게 실패합니다.

```
error: the argument '--print [<PROMPT>]' cannot be used with '[PATH]...'
```

**`-p` 를 빼먹으면 조용히 아무 일도 안 합니다.** `-p` 없이 돌리면 대화형 세션으로
들어가는데, 워커의 표준 입력은 `/dev/null` 이라 곧바로 **종료 코드 0** 으로 끝납니다.
`aw list` 에는 `done` 으로 보이지만 실제로 한 일은 없습니다. 무인 실행에서는 `-p` 가
필수입니다.

**작업 공간 신뢰 검사를 통과해야 합니다.** 신뢰 등록이 안 된 디렉터리에서 `-p` 로
돌리면 `Refusing to run in an untrusted workspace` 와 함께 **종료 코드 1** 로 실패합니다.
`aw wait` 가 잡아내니 조용히 넘어가지는 않습니다.

기본 옵션을 켜 두면 `--respect-workspace-trust false` 가 자동으로 붙어 통과합니다.
`-w` 로 worktree 를 쓸 거라면 사실상 필수입니다 — worktree 는 `aw run` 이 실행하는
순간 새로 만드는 경로라, "미리 한 번 대화형으로 실행해 신뢰 등록" 자체가 불가능합니다.

기본 옵션을 안 쓴다면 그 디렉터리에서 `devin` 을 한 번 직접 실행해 등록하세요.
설정 진단은 `devin doctor`.

**표준 입력은 받지 않습니다.** 파일로 프롬프트를 넣으려면 `aw` 의 `-f` 가 아니라
devin 자신의 `--prompt-file` 을 쓰세요.

```sh
aw run -n d2 -- devin -p --prompt-file spec.md
```

SWE-2 의 컨텍스트는 262K 입니다. `--model` 로 Claude·GPT·Gemini 를 쓰면 1M 이므로 한도 경고를 함께 조정하세요.

```sh
aw run -n g1 --max-input-tokens 1000000 -- devin -p "설계를 검토해줘" --model gemini-3-8-flash-high
```

### codex — OpenAI Codex CLI

```sh
npm install -g @openai/codex
codex          # 최초 1회 로그인 (또는 CODEX_API_KEY 환경변수)
```

`codex exec`가 비대화형 모드이고, **프롬프트를 stdin 으로 받을 수 있습니다**(`-`).
`claude`, `agy` 와 마찬가지로 `aw` 의 `-f` 를 그대로 쓸 수 있습니다.

```sh
aw run -n x1 -- codex exec --json "테스트를 추가해줘"
aw run -n x2 -f spec.md -- codex exec --json -     # 큰 프롬프트도 문제없음
```

출력은 JSONL(줄마다 JSON 이벤트)입니다. `aw result x1 --field text` 가 마지막 메시지(최종 답)를 꺼냅니다.

### kiro-cli — Kiro CLI

```sh
kiro-cli login                  # 최초 1회
kiro-cli chat --list-models     # claude-opus-5.5 등 확인
```

```sh
aw run -n k1 -- kiro-cli chat --output-format stream-json "테스트를 추가해줘"
aw run -n k2 -f spec.md -- kiro-cli chat --output-format stream-json     # 프롬프트 인자 생략
aw wait k1 && aw result k1 --field finalText
```

`--output-format stream-json` 은 사람 입력을 기다리지 않는 모드(`--no-interactive`)를 겸합니다. 도중 사건
(도구 호출, 답 조각)이 한 줄씩 쌓여 `aw peek` 으로 보이고, 마지막 줄에 `finalText` 와 `status`(`success`)가
있습니다. 답은 몇 글자짜리 조각으로 나눠 오는데, `aw peek` 은 이어 붙여 말 한 줄로 보여 주고 예상 소요 시간도 읽습니다.
`finalText` 는 그 턴의 말을 구분 없이 다 이어 붙인 것이라, 진행 줄을 남긴 작업이면 앞에 진행이 붙어 있습니다.

실측(2.24.1)으로 확인한 주의할 점 넷:

- **모델**: 기본 엔진(v2)은 `--model` 을 무시합니다. `failed to set model 'claude-opus-5.5': Method not found`
  경고를 남기고 Auto 로 돕니다. `--agent-engine v3` 에서는 따릅니다. 그래서 기본 옵션은 모델과 엔진을
  **따로** 붙입니다. `--model` 만 직접 줘도 엔진 줄은 붙고, 엔진을 직접 고르면(`--agent-engine v2`, `--v2`)
  엔진 줄이 빠집니다. `--v2` 와 `--agent-engine` 을 같이 주면 kiro-cli 가 오류를 내서 둘을 같은 옵션으로 봅니다.
- **권한**: `--trust-all-tools`(`-a`) 가 없으면 파일 쓰기·명령이 거부되는데도 **코드 0** 으로 끝나고
  `finalText` 에만 못 했다고 적힙니다. 기본 옵션을 켜 두면 붙습니다. `-a` 와 같이 주면 오류라 같은 옵션으로 봅니다.
- **프롬프트**는 `chat` 뒤 맨 끝 인자로 둡니다. `aw resume` 이 `chat --resume-id <sessionId>` 를 붙이고 맨 끝을 갈아 끼웁니다.
  v3 는 v2 로 시작한 세션도 이어받아서, 중간에 엔진이 바뀌어도 이어집니다.
- **거절**: 모델이 거절하면 도중에 멈추고도 마지막 `runFinished` 에 `status: success`, `stopReason: end_turn` 을 적고
  **코드 0** 으로 끝납니다. 답은 `The selected model cannot continue this conversation…` 뿐이고, 거절 사유는 턴 끝 사건의
  `stopReason: content_filtered` 와 `stopDetails.refusal.category` 에만 남습니다. `aw peek` 이 `주의` 줄로 사유와 함께
  알려 줍니다. 생각 과정을 적어 달라는 프롬프트는 생각 빼내기(`REASONING_EXTRACTION`)로 거절당했습니다(Opus 5.5,
  Opus 5 모두). 그래서 [지시문](#워커-지시문-brief)에서도 그런 문장을 뺐습니다.

생각하는 동안에도 생각 내용 조각이 몇 초마다 출력에 흘러서 `aw peek` 에 `생각 중: 약 N자째` 로 보입니다.

> claude·agy·devin·codex 는 379KB 파일 입력까지, kiro-cli 는 파일 쓰기·이어하기·모델 적용·7분짜리 작업의 중간 진행까지
> 실제로 돌려 확인했습니다. macOS 26.5 에서도 kiro-cli 워커의 실행·진행 보기·이어하기·멈추기를 확인했습니다.

### 워커로 쓸 수 없는 것

**GUI 기반 도구(Antigravity IDE, Cursor 등)는 안 됩니다.** VS Code 계열의 CLI 는 창을 여는
용도라 헤드리스로 돌지 않습니다. 같은 모델을 쓰고 싶으면 그 모델을 지원하는 CLI 에이전트를
쓰세요 — 예를 들어 Gemini 는 `agy` 나 `devin --model gemini-...` 로 돌립니다.

### 대화 이어하기

에이전트들은 대화를 이어갈 수 있게 세션 ID 를 내놓습니다. 이름이 제각각이라
(`session_id` / `conversation_id` / `thread_id` / `sessionId`) `aw` 가 끝난 워커의 출력에서
찾아 `meta` 에 적어 둡니다. `aw status` 에서 볼 수 있고 `aw list --json` 에도
`session` 으로 나옵니다.

```sh
aw run -n job -- agy --output-format stream-json -p='설계를 검토해줘'
aw wait job
aw resume job -- '방금 지적한 것 중 첫 번째를 고쳐줘'     # → job-r1
aw resume job-r1 -- '테스트도 추가해줘'                   # → job-r2
```

원래 명령을 그대로 물려받고 프롬프트만 갈아 끼웁니다. 실행할 명령을 화면에
찍어 주니 무엇이 붙었는지 바로 보입니다. 새 이름은 `<원래이름>-r1`, `-r2` 로
붙고 `-n` 으로 바꿀 수 있습니다. 작업 디렉터리와 `--profile` 도 물려받습니다.

| 에이전트 | 이어하기 | 비고 |
| --- | --- | --- |
| `claude` | `--resume <session_id>` | |
| `agy` | `--conversation <conversation_id>` | |
| `codex` | `codex exec resume <thread_id>` | 이 서브명령이 `--sandbox` 를 안 받아 기본 옵션을 자동으로 끕니다 |
| `devin` | `-c` | 텍스트만 내놓아 세션 ID 를 못 뽑습니다. 아래 참고 |
| `kiro-cli` | `kiro-cli chat --resume-id <sessionId>` | `chat` 으로 시작한 워커만 |

**`devin` 은 정확하지 않습니다.** 세션 ID 를 비대화형으로 얻을 길이 없어
`-c`(그 디렉터리의 **가장 최근** 대화)로 이어갑니다. 같은 디렉터리에 devin
워커가 여럿이면 엉뚱한 대화를 집을 수 있어서, 그럴 때 `aw` 가 경고를 냅니다.

**claude, codex, kiro-cli 는 프롬프트를 맨 끝 인자로 두세요.** 이어할 때 맨 끝을
프롬프트로 보고 걷어냅니다. `claude -p "프롬프트" --output-format stream-json --verbose` 처럼
가운데 두면 엉뚱한 걸 걷어냅니다. `-f` 로 넣었다면 걷어낼 게 없으니 그대로입니다.

`-e` 로 준 환경변수는 이어지지 않습니다. 필요하면 `aw resume` 에 다시 주세요.

### 프롬프트가 클 때

프롬프트를 명령 인자로 넘기는 방식(`agy -p "$(cat spec.md)"`)에는 **운영체제 한계**가 있습니다.
리눅스는 인자 **하나**의 크기를 128KB(`MAX_ARG_STRLEN`, 32 × 페이지 크기)로 제한합니다.
직접 재 보면 127KB 까지는 통과하고 128KB 부터 `argument list too long` 으로 실패합니다.
이건 셸이 `aw` 를 실행하기도 전에 거부하는 것이라 `aw` 가 대신 처리해 줄 수 없습니다.

| 프롬프트 크기 | 방법 |
| --- | --- |
| ~127KB 이하 | `-- agy -p="$(cat spec.md)"` 그대로 (특수문자까지 그대로 전달됩니다) |
| 그보다 크면 | 아래 파일 입력을 쓰세요. 크기 제한이 없습니다. |

파일로 프롬프트를 넣는 법은 에이전트마다 다릅니다. 넷은 표준 입력(`-f`)을 받고,
`devin` 만 자기 옵션을 씁니다.

| 에이전트 | 명령 |
| --- | --- |
| `claude` | `aw run -f spec.md -- claude -p --output-format stream-json --verbose` (프롬프트 인자 생략) |
| `agy` | `aw run -f spec.md -- agy --output-format stream-json` (`-p` 빼기) |
| `codex` | `aw run -f spec.md -- codex exec --json -` |
| `devin` | `aw run -- devin -p --prompt-file spec.md` (표준 입력 안 받음) |
| `kiro-cli` | `aw run -f spec.md -- kiro-cli chat --output-format stream-json` (프롬프트 인자 생략) |

큰 사양서는 파일로 두고 에이전트가 자기 도구로 읽게 하는 편이 토큰 면에서도 낫습니다.
필요한 부분만 읽기 때문입니다.

## 에이전트가 aw 를 쓰게 하기 (스킬)

[`skills/agent-worker/SKILL.md`](skills/agent-worker/SKILL.md) 는 [Agent Skills](https://agentskills.io/specification)
표준 형식의 스킬입니다. 설치해 두면 Claude Code, Codex, Hermes 같은 에이전트가 "codex 한테 리뷰시켜",
"gemini 로 두 번째 의견 받아 줘" 같은 요청에 스스로 `aw` 로 워커를 띄우고, 기다리고, 결과를 가져옵니다.
에이전트별 호출법, 파일을 고치는 작업은 `-w` 로 떼어 놓기, 워커 출력은 지시가 아니라 데이터로 다루기,
몇 시간짜리 작업을 셸 도구의 시간 제한(Claude Code 는 기본 120초)에 걸리지 않고 맡기는 법 같은
규칙이 들어 있고, 자세한 건 `aw help` 로 넘깁니다.

스킬은 에이전트가 읽고 따르는 지시문이라 **묻지 않고 넣지 않습니다.** `install.sh` 는 에이전트마다 묻고
(기본 아니오, [옵션](#설치)으로 미리 고를 수도 있음), 나중에 보거나 바꾸려면 `aw skill` 을 씁니다.

```
$ aw skill
에이전트 스킬: agent-worker (aw 0.8.0)

  에이전트  설치  상태     위치
  claude    있음  최신     ~/.claude/skills/agent-worker
  codex     있음  최신     ~/.agents/skills/agent-worker
  devin     있음  최신     ~/.agents/skills/agent-worker
  agy       있음  없음     ~/.gemini/config/skills/agent-worker
  hermes    없음  없음     ~/.hermes/skills/agent-worker

$ aw skill install agy          # 하나만 넣기 (이름을 빼면 있는 에이전트 전부)
$ aw skill install --ask        # 있는 에이전트마다 물어보며 넣기
$ aw skill update               # aw 를 올린 뒤, 이미 넣은 스킬만 새 버전으로
$ aw skill remove codex         # 빼기 (이름을 빼면 aw 가 넣은 것 전부)
$ aw skill show                 # 내용 보기
```

상태는 `최신` / `옛 버전`(aw 를 올린 뒤 다시 안 넣음) / `없음` / `남의 것`(같은 이름의 다른 스킬) 입니다.
에이전트가 있는지는 CLI 가 PATH 에 있거나 설정 폴더가 있는지로 봅니다.

처음 설정이나 새 에이전트를 깐 뒤에는 **`aw setup`** 이 편합니다. 권한 옵션, 에이전트 CLI, 스킬, PATH 를
차례로 점검하고, 터미널에서 돌리면 빠진 것마다 물어봅니다(권한 옵션과 새 스킬은 기본 `아니오`,
이미 넣은 스킬을 새 버전으로 바꾸는 건 기본 `예`).
터미널이 아니면 점검만 하고 아무것도 바꾸지 않습니다. 없는 에이전트 CLI 는 설치하지 않고 설치 명령만 알려 줍니다.

```
$ aw setup
[1/4] 권한 옵션
  켜져 있음: ~/.config/agent-worker/defaults   (내용: aw defaults)
[2/4] 에이전트 CLI
  claude    있음  ~/.local/bin/claude
  hermes    없음  설치: https://hermes-agent.nousresearch.com 의 설치 안내
  ...
[3/4] 에이전트 스킬
  agy           없음     ~/.gemini/config/skills/agent-worker
    넣을까요? [y/N]
```

에이전트마다 스킬을 읽는 폴더가 달라 각각 복사합니다.

| 에이전트 | 넣는 곳 | 확인 |
| --- | --- | --- |
| Claude Code | `~/.claude/skills/` | 실측 (2.1.280). `~/.agents/skills` 는 읽지 않음 |
| Codex | `~/.agents/skills/` | 실측 (codex-cli 0.145). `~/.codex/skills` 도 읽어서, 두 번 보이지 않게 거기엔 안 넣음 |
| Devin | `~/.agents/skills/` (Codex 와 같은 곳) | 실측 (3000.11). `~/.claude/skills` 도 읽어서 Claude Code 도 있으면 두 번 보임 (충돌은 없음) |
| agy | `~/.gemini/config/skills/` | 실측 (1.2.9). `~/.agents/skills` 는 읽지 않음 |
| Hermes | `~/.hermes/skills/` | 문서 기준. 저장소에서 바로 받을 수도 있음: `hermes skills install shaichoi/agent-worker/skills/agent-worker` |

- 같은 이름의 다른 스킬이 이미 있으면 덮어쓰지 않습니다. `aw skill remove` 와 `./uninstall.sh` 는 `aw` 가 넣은 것만 지웁니다.
- 새로 넣은 스킬은 에이전트를 새로 시작해야 보입니다.
- 스킬 내용은 `aw` 안에 들어 있어서 인터넷 없이 넣을 수 있고, 늘 그 `aw` 의 버전과 맞습니다.
  저장소의 `SKILL.md` 는 `aw skill show` 로 만든 것입니다. 고칠 때는 `aw` 의 `skill_text` 를 고치고
  `./aw skill show > skills/agent-worker/SKILL.md` 로 다시 만듭니다(테스트가 둘이 같은지 봅니다).

**Codex 는 샌드박스가 걸립니다.** Codex 의 기본 `workspace-write` 샌드박스에서는 작업 폴더 밖에 쓸 수 없고
네트워크도 막혀서, `aw` 가 워커 기록(`~/.local/share/agent-worker`)을 못 남기고 띄운 에이전트도 API 에
닿지 못합니다(실측: `Read-only file system`). 스킬은 Codex 에게 `aw` 명령을 샌드박스 밖에서 돌리도록
승인을 요청하라고 알려 줍니다.

- **대화형 Codex**(평소 쓰는 화면)는 `aw` 명령마다 이유를 붙여 승인 창을 띄우고, 승인하면 샌드박스 밖에서
  돌아 끝까지 됩니다(실측: agy 워커를 띄워 답을 받아 옴). 승인 창의
  **"Yes, and don't ask again for commands that start with `aw` (p)"** 를 고르면 그 뒤로는 묻지 않습니다
  (이 선택을 Codex 가 어디에, 얼마나 오래 기억하는지는 확인하지 않았습니다).
- **비대화형 `codex exec`** 는 승인할 사람이 없어 `aw` 를 쓸 수 없습니다. 샌드박스 때문이라고 알리고 멈춥니다(실측).
- 승인 창 대신 미리 허용해 두려면 Codex 의 [규칙](https://developers.openai.com/codex/rules)을 쓸 수 있습니다(문서 기준).
  그러면 Codex 가 승인 없이 `aw` 로 아무 명령이나 샌드박스 밖에서 돌릴 수 있게 된다는 점을 감안하세요.

  ```
  # ~/.codex/rules/default.rules
  prefix_rule(pattern=["aw"], decision="allow")
  ```

반대로 `aw` 로 띄운 Codex 워커(`codex exec`, 기본 옵션 `--sandbox workspace-write`)는 그 안에서 `aw` 를
돌릴 수 없어서, 워커가 워커를 또 띄우지 못합니다.

**워커가 워커를 낳지 않게** 워커 안에는 환경변수 `AW_WORKER`(그 워커 이름)가 들어 있습니다. 스킬은 이게 있으면
프롬프트가 분명히 요구하지 않는 한 워커를 더 띄우지 않도록 합니다.

## 워커 지시문 (brief)

워커 프롬프트 **앞에** 붙는 지시문입니다. 권장값은 두 가지를 부탁합니다.

```
작업을 시작하기 전에, 첫 줄에 예상 소요 시간을 이 형식으로 적으세요: "예상 소요: 약 N분" (범위면 "예상 소요: 약 M~N분").
작업이 5분 넘게 걸리면 몇 분마다 지금 하는 일을 한 줄로 적으세요.
```

- **예상 소요 시간**을 `aw peek` 이 찾아 경과와 견줘 보여 줍니다(`예상 소요 : 약 15분 (3m 지남)`, 넘기면 `예상보다 5m 더 걸리는 중`).
  에이전트가 쓴 글에서만 찾아서, 프롬프트에 든 지시문의 예시를 답으로 읽지 않습니다.
- **중간 진행 한 줄**은 오래 도는 작업이 어디까지 왔는지 `aw peek` 의 최근 활동에 말로 보여 줍니다.
  kiro-cli 는 7분짜리 작업에서 단계마다 `1회차 완료, 2회차 실행 중입니다.` 처럼 남겼습니다(실측).
  모델이 얼마나 따르는지는 모델마다 다릅니다.
- **생각 과정을 적어 달라고는 하지 않습니다.** 0.12.0 까지의 권장값에는 "오래 생각해야 할 때도 한 번에 다
  생각하지 말고, 중간에 한 줄씩 진행을 남기며 이어 가세요" 가 있었습니다. 머리로 푸는 문제와 만나면 kiro-cli 의
  모델이 이를 생각 빼내기(`REASONING_EXTRACTION`)로 보고 거절해 도중에 멈췄습니다(실측: 4번 중 4번. 그 문장을
  빼면 3번 중 3번 정답, claude 는 그 문장이 있어도 정상). 예전 지시문을 쓰고 있으면 `aw brief` 와 `aw setup` 이
  알려 줍니다. `aw brief --init --force` 로 새 권장값을 받습니다.

```sh
aw brief                  # 지금 붙는 지시문
aw brief --init           # 권장값으로 켜기 (있으면 덮어쓰지 않음, --force 로 되돌리기)
aw run --no-brief -- ...  # 이번만 끄기 (그 셸에서 끄려면 AW_NO_BRIEF=1)
rm ~/.config/agent-worker/brief   # 아예 끄기
```

`install.sh` 가 설치할 때 권장값으로 켜 줍니다(`--no-brief` 면 안 켬). 파일은 마음대로 고쳐 써도 되고,
`#` 로 시작하는 줄은 붙지 않습니다.

붙는 곳은 프롬프트 위치를 아는 에이전트뿐입니다. 모르는 명령(빌드 스크립트 등)에는 붙이지 않습니다.

| 에이전트 | 붙는 곳 |
| --- | --- |
| claude, codex | 맨 끝 인자(프롬프트), 또는 `-f` 로 넣은 표준 입력 (codex `-`) |
| kiro-cli | `chat` 뒤 맨 끝 인자, 또는 `-f` 로 넣은 표준 입력 |
| agy | `-p='...'` / `-p ...` 의 값, 또는 `-f` 로 넣은 표준 입력 |
| devin | `-p` 바로 뒤 프롬프트, 또는 `--prompt-file` (지시문을 앞에 붙인 새 파일로 바꿔 넘김, 원래 파일은 그대로) |

`aw resume` 으로 이어할 때도 새 프롬프트에 한 번 붙어서, 추가 작업의 예상 시간을 다시 받습니다.
워커 기록의 `cmd.orig` 에는 붙이기 전 인자가, `cmd` 에는 실제로 넘긴 인자가 남습니다.

## 에이전트 고르기 (aw pick, 실험용)

작업을 [TypeSafe AI](https://typesafe.ai/) 의 **Jev** 에 보내 어느 에이전트가 맞는지, 그 에이전트의 어느 모델·추론 수준이
맞는지 고르게 하고 그대로 워커를 띄웁니다. Jev 는 글을 짓지 않고 정해 준 선택지 중 하나를 확신도와 함께 고르는 모델이라, 에이전트 고르기처럼
좁은 결정에 빠르고 쌉니다. 고른 뒤에는 그 에이전트의 정석 호출(`aw help agents`)로 `aw run` 을 부르므로
기본 옵션, 지시문, `-w` worktree 가 평소처럼 붙습니다. **실험용이라 꺼져 있고, 켜야 씁니다.**

```sh
aw pick on --key "$KEY"                       # 켜기 + 키 저장 (--key 를 빼면 터미널에서 가려서 물어봄)
aw pick --dry-run -- 'src/auth 를 검토해줘'    # 고르기만: 고른 것, 확신, 띄울 aw run 명령
aw pick -n review -- 'src/auth 를 검토해줘'    # 골라서 띄움
aw pick -n spec -w feat/x -f task.md          # 파일의 작업으로 (에이전트에도 파일로 넘김)
aw pick                                       # 상태: 켜짐, 키, 후보
aw pick off                                   # 끄기 (고친 설명과 키는 남겨 둠, aw pick on 으로 돌아옴)
```

```
고른 에이전트: codex   확신 0.99   (codex 1.00 · agy 0.00 · claude 0.00 · devin 0.00 · kiro-cli 0.00)
고른 모델    : gpt-6-astra@xhigh   확신 0.96   (gpt-6-astra@xhigh 0.97 · gpt-6-sol@high 0.03 · gpt-6-luna@medium 0.00)
워커 시작: review
  명령: codex exec --json --model gpt-6-astra -c model_reasoning_effort=xhigh src/auth 를 검토해줘
```

- **고르는 기준**은 `~/.config/agent-worker/pick` 의 설명입니다. 에이전트 줄 아래 들여 쓴 줄이 그 에이전트의
  모델 선택지입니다.

  ```
  codex OpenAI Codex CLI (GPT-6). For reviewing and critiquing existing material without changing it ...
    gpt-6-luna@medium GPT-6 Luna, fast and affordable, medium reasoning. For a quick, low-risk check ...
    gpt-6-sol@high GPT-6 Sol, OpenAI's workhorse coding model, high reasoning. The ordinary choice ...
    gpt-6-astra@xhigh GPT-6 Astra, ... For a review where a missed problem would be costly ...
  ```

  Jev 에는 요청 한 번에 Choice 질문을 여럿 보냅니다. 에이전트 하나, 그리고 모델 줄이 둘 이상인 후보마다 모델
  하나이고, 고른 에이전트의 모델 답만 씁니다(Jev 문서의 speculative fan-out). 선택지는 PATH 에 있는 에이전트뿐입니다.
  작업이 에이전트나 모델을 짚으면("codex 로 …") 그걸 고르라고 함께 보냅니다. 후보에서 빼려면 그 줄을 지우거나
  `#` 로 막고, 모델까지 고를 필요가 없으면 들여 쓴 줄을 지웁니다(그 에이전트는 기본값으로 돔).
  Jev 는 영어를 가장 잘 읽어 설명은 영어로 두는 편이 낫습니다.
- **권장 설명**은 실측으로 다듬었습니다. 다섯 CLI 의 모델·수준 목록을 실측으로 모으고, 초안을 codex 와 devin 에게
  `aw run` 으로 검토받은 뒤 네 가지 안을 실제 Jev 로 견줬습니다. 시험 작업은 `tests/pick-eval/` 에 있습니다.
  - `tasks.txt` (26개, 다듬을 때 쓴 것): 에이전트 26/26, 모델까지 25/26.
  - `heldout.txt` (24개, 정책만 주고 codex 가 따로 만든 것): 에이전트 24/24, 모델까지 18/24. 모델이 틀린 6개 중
    4개는 확신이 낮아 기본값으로 갔고 2개는 옆 단계를 골랐습니다. 권장 설명을 쓸 때 이 세트는 보지 않았지만, 결과를 본
    뒤 규칙 하나(Luna·Sol·Astra, Flash·Pro 라는 이름을 codex·agy 가 가져감)를 고쳤습니다. 고치기 전 에이전트는 22/24 였습니다.
  - codex 줄은 0.15.0 에서 GPT-5.6 에서 GPT-6 세대(luna / sol / astra)로 바꿨습니다. 그러면서 "Sol 로 꼼꼼히" 처럼 이름과
    난이도가 다른 줄을 가리키는 작업이 생겨, 보류 세트의 모델 점수가 19/24 에서 18/24 로 내려갔습니다(그 작업은 기본값으로 감).
  - 다시 재려면 `tests/pick-eval/run.sh [설명 파일]` (실제 Jev 에 작업마다 한 번 요청, 키 필요).

  정답표는 "누가 무엇을 맡는가" 라는 정책을 따른 것이라, Jev 가 그 정책대로 고르는지만 잽니다. 그 정책이 실제로 최선인지
  (예: 리뷰는 정말 codex 가 나은지, Gemini Pro 가 Flash 보다 나은지)는 재지 않습니다. 설명은 써 보며 고치세요.
- **추론 수준**은 `모델@수준` 으로 적고, aw 가 에이전트마다 맞는 옵션으로 바꿉니다: claude·agy `--effort`,
  codex `-c model_reasoning_effort=`, devin 은 이름에 이어 붙임(`swe-2@max` → `swe-2-max`). kiro-cli 는
  `--agent-engine v3` 를 같이 붙입니다(기본 엔진은 `--model` 을 무시). kiro-cli 의 `--effort` 는 실측에서 먹지
  않아서(모델을 바꾸면 세션이 `high` 로 잡힘) 권장값에는 수준을 적지 않았습니다.
- **확신이 낮으면 띄우지 않습니다.** 에이전트 확신이 `--min-confidence`(기본 0.5)보다 낮으면 분포만 보여 주고
  코드 3 으로 끝납니다. 직접 `aw run` 으로 고르거나, 1등을 그대로 쓰려면 `--min-confidence 0`. 모델 확신이 낮으면
  워커는 띄우고 모델만 기본값으로 둡니다.
- 후보나 모델 줄이 하나뿐이면 묻지 않고 그걸 씁니다. 고른 결과는 워커 `meta` 의 `picked`, `pick_confidence`,
  `pick_model`, `pick_model_confidence` 에 남고 `aw status` 에 보입니다.
- 종료 코드: `0` 띄움 (Jev 를 못 써서 대신 띄운 것 포함) / `1` 오류 (꺼짐, `--fallback none`, 대신 띄울 에이전트가 없음) /
  `3` 확신이 낮아 안 띄움.

**안 될 때**

- **Jev 를 못 쓰면** (키 없음, 네트워크, 402·403 권한·예산, 429 한도, 5xx 서버 오류, 읽을 수 없는 답) 일이 막히지 않게
  설명 파일의 첫 후보(권장값에서는 claude)로 띄웁니다. 모델은 기본값이고, 이유는 경고와 `meta` 의 `pick_jev_error` 에
  남습니다. 대신 띄울 에이전트는 `--fallback <에이전트>` 나 `AW_PICK_FALLBACK` 으로 바꾸고, `none` 이면 띄우지 않고
  코드 1 로 끝납니다. 요청 한 번은 연결 5초·전체 20초에서 끊고, 429·5xx 는 두 번, 연결 실패는 한 번 더 해 봅니다.
- **고른 모델을 에이전트가 거부하면** (없는 모델, 쓸 권한 없음) 같은 워커에서 모델 옵션만 빼고 한 번 더 돌립니다.
  워커가 2분 안에 실패하고 출력에 모델 탓이라는 문구가 있을 때만입니다. 실측으로 claude, codex, agy, devin, kiro-cli
  모두 없는 모델을 받으면 0~6초 안에 코드 1 과 그런 문구(`Unknown model`, `Invalid model ID` 등)를 냈습니다. 첫 시도는
  `out.model`, `err.model` 에, `meta` 에는 `pick_fallback` 이 남고, `aw resume` 은 다시 돈 명령으로 이어 갑니다.

**키**는 [console.typesafe.ai/keys](https://console.typesafe.ai/keys) 에서 받고, 셋 중 편한 방법으로 넘깁니다.
찾는 순서는 `--key` 인자, `TYPESAFE_API_KEY` 환경변수(TypeSafe SDK 와 같은 이름), `aw pick key` 로 저장한 파일입니다.

```sh
TYPESAFE_API_KEY=... aw pick -- '작업'       # 환경변수
aw pick --key ... -- '작업'                  # 이번만 인자로 (저장하지 않음)
printf '%s\n' "$KEY" | aw pick key           # 저장 (~/.config/agent-worker/typesafe-key, 나만 읽기 권한)
aw pick key "$KEY"                           # 인자로 저장
```

인자로 준 키는 셸 기록과 `aw` 프로세스의 `ps` 에 남을 수 있습니다. 기록이 걱정되면 환경변수나 표준 입력을 쓰세요.
`aw` 는 키를 `curl` 의 명령 인자에 싣지 않고(설정을 표준 입력으로 넘김) 워커 기록에도 남기지 않습니다.
Jev 로 보내는 것은 작업 글의 앞 12KB 와 후보 설명뿐이고, 저장소 파일은 보내지 않습니다. `curl` 이 필요합니다.

## 모델 목록 (aw models)

설치된 CLI 가 스스로 알려 주는 모델 목록을 가져와, 정해 둔 모델이 그 컴퓨터에서 실제로 쓸 수 있는지 봅니다.

```sh
aw models                   # 에이전트마다 모델 수, CLI 의 기본, 기본 옵션의 모델이 목록에 있는지
aw models devin             # 그 에이전트의 모델 이름, 한 줄에 하나 (CLI 의 기본은 앞에 '* ')
aw models --refresh         # CLI 에게 다시 물어 캐시를 새로 씀
```

```
에이전트  모델  CLI 기본            목록
claude    -     -                   목록 명령이 없어 확인하지 않음
codex     9     gpt-6-astra         ~/.codex/models_cache.json (codex 가 관리)
agy       14    -                   캐시 2m 전
            기본 옵션 --model gemini-3.8-flash: 목록에 있음
devin     704   -                   캐시 2m 전
            기본 옵션 --model swe-2-max: 목록에 있음
kiro-cli  20    auto                캐시 2m 전
            기본 옵션 --model claude-opus-5.5: 목록에 있음
```

- **정한 기본이 먼저입니다.** 기본 옵션(`aw defaults`)의 모델을 붙이기 전에 그 CLI 의 목록에 있는지 봅니다. 없으면(모델이
  바뀌었거나 없어졌으면) 그 줄을 빼서 CLI 자체의 기본 모델로 띄우고, `aw run` 출력과 워커 `meta` 의
  `default_model_dropped` 에 남깁니다. 다른 줄(권한 등)은 그대로 붙습니다.
- **목록을 모르면 정한 기본 그대로입니다.** claude 는 목록 명령이 없고, 설치 안 된 CLI 나 조회에 실패한 CLI 도
  확인하지 않습니다.
- `aw pick` 은 목록에 없는 모델 줄을 Jev 에 보내지 않습니다. `aw pick` 상태에는 `(목록에 없음)` 으로 보입니다.
- 목록을 얻는 곳: codex 는 `~/.codex/models_cache.json` 과 `config.toml` 의 `model`(기본), agy 는 `agy models`, devin 은
  `devin models list`(모델 ID·계열·별칭 모두, `--model` 이 셋 다 받음), kiro-cli 는 `kiro-cli chat --list-models`(`*` 가 기본).
  agy 는 `gemini-3.8-flash` 처럼 수준을 뗀 이름도 목록의 `gemini-3.8-flash-high` 와 맞는 것으로 봅니다(`--effort` 와 함께 씀).
- 목록 명령이 느려서(실측: kiro-cli 1.4초, agy 4.7초, devin 5.5초) `~/.local/share/agent-worker/models/` 에 캐시합니다.
  `aw run` 은 캐시만 읽고, **찾는 모델이 캐시에 없을 때만** 한 번 새로 물어본 뒤 정합니다. 낡은 캐시 때문에 멀쩡한 기본을
  빼지 않고, 새로 받지 못하면 빼지 않습니다. codex 는 스스로 관리하는 파일을 그때그때 읽습니다.

## 기본 옵션 (권한 우회, 모델)

무인 워커는 승인 프롬프트를 만나면 멈추거나 조용히 거부됩니다. 그래서 에이전트별로
"사람 없이 돌 때" 필요한 옵션을 **명령 뒤에 자동으로 붙일 수 있습니다.** 모델을 따로
말하지 않았을 때 쓸 모델(agy, devin, kiro-cli)도 같은 파일에 둡니다.

권한을 올리는 일이라 `aw` 가 제멋대로 하지 않습니다. **설정 파일이 있을 때만**
적용합니다. `install.sh` 가 설치할 때 그 파일을 만들어 주므로 안내대로 설치했다면
아래 표가 바로 적용됩니다. 원하지 않으면 `./install.sh --no-defaults` 로 설치하거나
나중에 파일을 지우면 됩니다.

```sh
aw defaults                            # 지금 적용 중인 것 (파일 내용과, 파일에 없는 권장값)
aw defaults get agy                    # agy 에 붙는 묶음을 한 줄에 하나씩
aw defaults get agy --model            # 그중 --model 이 든 묶음만 → --model gemini-3.8-flash --effort high
aw defaults set agy --model gemini-3.1-pro-high    # 옵션이 겹치는 줄을 바꿈 (없으면 넣음)
aw defaults set agy --model gemini-3.8-flash --effort medium   # 줄이 통째로 바뀌니 수준만 바꿀 때도 모델을 같이
aw defaults unset agy --model          # 그 줄을 뺌 (옵션을 빼면 그 명령의 줄 전부)
aw defaults --init                     # 권장값으로 켜기 (--force 면 되돌리기)
rm ~/.config/agent-worker/defaults     # 끄기
```

```sh
$ aw run -n a1 -- agy -p='리팩터링'
워커 시작: a1
  명령: agy -p=리팩터링 --dangerously-skip-permissions --model gemini-3.8-flash --effort high
  (기본 옵션이 붙었습니다: --dangerously-skip-permissions --model gemini-3.8-flash --effort high — 끄려면 --no-defaults)
```

| 명령 | 붙는 옵션 (한 줄이 한 묶음) |
| --- | --- |
| `agy` | `--dangerously-skip-permissions` |
| | `--model gemini-3.8-flash --effort high` |
| `claude` | `--permission-mode bypassPermissions` |
| `devin` | `--permission-mode dangerous --respect-workspace-trust false` |
| | `--model swe-2-max` |
| `codex` | `--sandbox workspace-write` |
| `kiro-cli` | `--trust-all-tools` |
| | `--model claude-opus-5.5` |
| | `--agent-engine v3` (기본 엔진 v2 는 `--model` 을 무시해서, [위](#kiro-cli--kiro-cli) 참고) |

- **설정 파일이 없으면 아무것도 붙지 않습니다.** 파일을 받아 바로 실행한 사람에게
  권한이 조용히 올라가는 일은 없습니다. 파일이 없을 때 `aw defaults set` 을 하면 그 줄만 든
  파일을 만듭니다(권한 우회는 켜지 않음)
- 붙인 내용은 **항상 화면에 찍습니다**
- **한 줄이 한 묶음입니다.** 한 명령의 줄을 모두 붙이되, 그 줄의 옵션 중 **하나라도** 이미 있으면
  그 줄 전체를 건너뜁니다. 그래서 `--model` 이나 `--effort` 를 직접 주면 agy 의 모델 줄만 빠지고
  권한 줄은 붙습니다. `--effort low` 만 주면 모델도 같이 빠져 agy 자체 기본 모델로 돌므로, 그때는
  `--model gemini-3.8-flash --effort low` 로 둘 다 줍니다. 같은 옵션이 여러 줄에 있으면 앞 줄만 붙습니다
- 그 대신 한 줄 안의 옵션은 같이 붙고 같이 빠집니다. `devin` 에 `--permission-mode` 를 직접 주면
  `--respect-workspace-trust false` 도 함께 빠져 worktree 에서 실패합니다. 그때는 둘 다 직접 넘기거나
  줄을 나누세요
- 한 번만 끄려면 `--no-defaults`, 그 셸에서 끄려면 `AW_NO_DEFAULTS=1`
- 파일을 직접 고쳐도 됩니다. `~/.config/agent-worker/defaults` 에 `명령이름 옵션...` 한 줄씩
  (`#` 뒤는 주석). 값에 공백이 든 옵션은 적을 수 없습니다
- **예전에 설치했다면** 파일이 그대로 남아 새 권장값(kiro-cli, 모델)이 없습니다. `aw defaults` 가
  "권장값 중 이 파일에 없는 줄" 로 알려 주니 `aw defaults set` 으로 넣거나, 고친 게 없으면
  `aw defaults --init --force` 로 새 권장값을 받습니다. 주석 처리해 끈 줄은 알리지 않습니다

```
myagent --yolo --quiet
agy --model gemini-3.1-pro-high
kiro-cli --model claude-sonnet-5
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
| `devin` | 262,000 | Devin 자체 모델 SWE-2 / SWE-1.7 이 262K (`devin models list` 확인). 기본 옵션을 켜 두면 SWE-2 |
| `claude` | 1,000,000 | Claude Opus 5 (`claude -p --output-format json` 의 `contextWindow`) |
| `agy` | 1,000,000 | Antigravity CLI 기본 Gemini 계열 |
| `codex` | 400,000 | 참고값 |
| `kiro-cli` | 1,000,000 | Claude Opus 5.5 (`kiro-cli chat --list-models` 의 "1M context window") |
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
| `fallback.sh`, `out.model`, `err.model` | `aw pick` 이 고른 모델이 거부될 때 대신 돌리는 스크립트와 첫 시도의 출력 |

상태는 `running`(pid 살아 있음), `done`(코드 0), `failed`(0 아님), `stopped`(`aw stop`),
`lost`(종료 코드 없이 프로세스가 사라짐)입니다.

## 환경변수

| 변수 | 기본값 | 쓰임 |
| --- | --- | --- |
| `AW_HOME` | `~/.local/share/agent-worker` | 워커 기록 위치 |
| `AW_CONFIG` | `~/.config/agent-worker/contexts` | 컨텍스트 한도 설정 파일 |
| `AW_DEFAULTS` | `~/.config/agent-worker/defaults` | 에이전트별 기본 옵션(권한, 모델) 파일 |
| `AW_NO_DEFAULTS` | (없음) | `1` 이면 기본 옵션을 붙이지 않음 |
| `AW_PREFIX` | `~/.local/bin` | `install.sh` / `uninstall.sh` 의 설치 위치 |
| `AW_WORKER` | (워커 안에서만) | `aw` 가 워커에 넣어 주는 그 워커 이름. 중첩 확인용 |
| `AW_QUIET` | `300` | `aw peek` 이 조용함을 알리는 기준(초) |
| `AW_BRIEF` | `~/.config/agent-worker/brief` | 워커 지시문 파일 |
| `AW_NO_BRIEF` | (없음) | `1` 이면 지시문을 붙이지 않음 |
| `AW_PICK` | `~/.config/agent-worker/pick` | `aw pick` 의 후보 설명 파일 (있으면 켜짐) |
| `AW_PICK_KEYFILE` | `~/.config/agent-worker/typesafe-key` | `aw pick key` 가 키를 저장하는 파일 |
| `AW_PICK_MIN_CONFIDENCE` | `0.5` | `aw pick` 이 띄우는 확신 하한 |
| `AW_PICK_FALLBACK` | (설명 파일의 첫 후보) | Jev 를 못 쓸 때 대신 띄울 에이전트. `none` 이면 멈춤 |
| `TYPESAFE_API_KEY` | (없음) | Jev 키. 저장한 파일보다 먼저 쓰임 (`--key` 가 그보다 먼저) |
| `TYPESAFE_DEFAULT_MODEL` / `TYPESAFE_BASE_URL` | `jev-latest` / `https://api.typesafe.ai` | `aw pick` 이 부르는 모델과 주소 |

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
잘게 쪼개 많이 띄우는 건 오히려 비쌉니다. 비용은 `aw result <이름> --field total_cost_usd`로
확인할 수 있습니다(Claude Code 의 `stream-json`·`json` 결과).

**승인 프롬프트가 필요한 작업은 멈춰 있을 수 있습니다.** 비대화형으로 도구를 쓰는 에이전트는
권한을 물어볼 자리가 없습니다. `claude`라면 `--permission-mode`를 함께 넘기세요. 상태가
오래 `running`이면 `aw peek`으로 지금 도는 명령과 마지막 활동 시각을 보고, 그다음 `aw errs`를 보세요.

**`stop`은 하위 프로세스까지 끊습니다.** 프로세스 그룹째 끊고, 부모-자식 관계로 찾은 하위 프로세스도
전부 끊습니다. 에이전트는 도구 명령(테스트 러너, 빌드 등)을 새 세션으로 떼어 띄워서 그룹째 끊어도
남기 때문입니다(실측: claude, codex). `setsid`가 없는 macOS 도 이렇게 정리됩니다(실측). 다만 하위 프로세스가
스스로 부모와 연을 끊고 떠나 버린(데몬이 된) 경우는 찾을 수 없습니다.

**출력은 파일에 그대로 쌓입니다.** 매우 긴 작업이면 `out` 파일이 커질 수 있으니
`aw clean`으로 주기적으로 정리하세요.

## 제거

```sh
./uninstall.sh
```

실행 파일과 `aw` 가 넣은 스킬만 지우고 워커 기록은 남깁니다. 기록까지 지우려면 `--purge`를 주세요
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
