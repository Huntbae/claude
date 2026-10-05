# voicebox-kr

[Voicebox](https://github.com/jamiepine/voicebox)(오픈소스 로컬 AI 음성 스튜디오)를 한국어 내레이션 작업에 바로 쓸 수 있게 묶은 구성입니다.

| 폴더 | 내용 |
|---|---|
| `docs/01-기술검토.md` | 기능, 한국어 지원, 라이선스, 법적 위험 검토 보고서 |
| `client/voicebox_kr.py` | 한국어 내레이션 CLI. 대본 파일을 문단별 WAV 파일로 일괄 생성 |
| `deploy/` | Docker 운영 구성(CPU 기본, NVIDIA GPU 옵션). 업스트림 버전 고정 |
| `mcp/` | Claude Code에서 Voicebox를 MCP 서버로 쓰는 설정 |
| `examples/` | 예제 대본 |

## 1단계: Voicebox 서버 실행 (둘 중 하나 선택)

### A. 데스크톱 앱 (Mac, Windows 권장)

1. https://voicebox.sh 에서 설치 파일을 받아 설치하고 실행합니다.
2. 앱이 켜져 있으면 서버 주소는 `http://127.0.0.1:17493` 입니다. 클라이언트의 기본값이므로 따로 설정할 것이 없습니다.

Apple Silicon Mac은 MLX 가속을 쓰므로 Docker보다 데스크톱 앱이 훨씬 빠릅니다.

### B. Docker (Linux, 서버, 헤드리스 환경)

```bash
cd voicebox-kr/deploy
./setup.sh          # NVIDIA GPU가 있으면 ./setup.sh --gpu
export VOICEBOX_URL=http://127.0.0.1:17600
```

- 처음 빌드할 때 10~30분 정도 걸립니다.
- 웹 UI는 http://127.0.0.1:17600 에서 열립니다.
- 생성된 음성은 `deploy/output/` 에도 저장됩니다.
- Windows에서는 WSL2 터미널에서 실행합니다.
- 메모리가 부족하면 `VOICEBOX_MEMORY=12G ./setup.sh` 처럼 늘립니다.

## 2단계: 한국어 음성 준비

Python 3.9 이상만 있으면 되고, 별도 패키지 설치는 필요 없습니다.

```bash
cd voicebox-kr/client
python3 voicebox_kr.py health      # 서버 연결 확인
python3 voicebox_kr.py init-ko     # 한국어 기본 음성 "소희 (한국어 기본)" 생성
```

내 목소리를 쓰고 싶다면, 조용한 곳에서 5~30초 정도 녹음한 파일과 녹음에서 실제로 말한 문장을 함께 넣습니다.

```bash
python3 voicebox_kr.py clone "내 목소리" \
  --audio my_voice.wav \
  --text "안녕하세요. 오늘은 정책 이야기를 쉽게 풀어 보겠습니다." \
  --i-have-consent
```

`--i-have-consent` 는 본인이거나 화자에게서 명시적인 동의를 받았다는 확인입니다. 이 옵션이 없으면 실행되지 않습니다(근거: 부정경쟁방지법 제2조제1호타목).

## 3단계: 음성 만들기

문장 하나를 만들 때:

```bash
python3 voicebox_kr.py say "안녕하세요. 정책 해설 채널입니다." -o hello.wav
python3 voicebox_kr.py say -f intro.txt -p "내 목소리" -o intro.wav --instruct "차분하고 또박또박하게"
```

대본 전체를 만들 때(유튜브 내레이션 용도):

```bash
python3 voicebox_kr.py batch ../examples/episode-sample.txt
# -> ../examples/episode-sample/001.wav, 002.wav, 003.wav, manifest.json
```

- 대본은 빈 줄로 문단을 나눕니다. 문단마다 파일이 하나씩 만들어지므로, 편집 프로그램에서 컷 단위로 배치하기 쉽습니다.
- `#` 으로 시작하는 줄은 메모로 취급되어 읽지 않습니다.
- 중간에 끊기면 `--resume` 을 붙여 다시 실행합니다. 이미 만든 문단은 건너뜁니다.
- `manifest.json` 에 문단별 파일명, 길이(초), 원문이 기록됩니다.

### 자주 쓰는 옵션

| 옵션 | 설명 |
|---|---|
| `-p, --profile` | 사용할 음성 프로필(기본: 소희) |
| `--model-size 0.6B` | 가벼운 모델. GPU가 없으면 이 옵션을 권장 |
| `--instruct "..."` | 말투 지시. Qwen 계열 엔진에서 작동 |
| `--seed 42` | 같은 결과를 다시 만들 때 사용 |
| `--engine` | `qwen`, `qwen_custom_voice`, `chatterbox` 중 선택. 한국어를 지원하지 않는 엔진은 자동으로 차단 |
| `--timeout` | 문단당 최대 대기 시간(초). 기본 1800초. 첫 실행 때는 모델 다운로드 때문에 오래 걸림 |

그 밖의 명령:

```bash
python3 voicebox_kr.py profiles          # 프로필 목록
python3 voicebox_kr.py presets           # 프리셋 화자 목록(한국어 표시)
python3 voicebox_kr.py models --korean   # 한국어 모델 다운로드 상태
```

## Claude Code 연동 (선택)

Voicebox가 실행 중일 때 아래 명령을 한 번 실행하면, Claude Code가 작업 결과를 음성으로 읽어 주거나 음성 파일을 받아쓸 수 있습니다.

```bash
claude mcp add --transport http voicebox http://127.0.0.1:17493/mcp/ \
  --header "X-Voicebox-Client-Id: claude-code"
```

Docker를 쓴다면 포트를 `17600` 으로 바꿉니다. 업스트림 README에 나온 `--url` 옵션은 현재 Claude Code CLI에 없으므로 위 형식을 사용합니다. 프로젝트 단위로 설정하려면 `mcp/claude-code.mcp.json` 의 내용을 프로젝트 루트의 `.mcp.json` 에 넣습니다.

사용 예: "작업 끝나면 소희 목소리로 요약해서 말해줘"라고 하면 Claude Code가 `voicebox_speak` 도구를 호출합니다.

## 문제 해결

| 증상 | 조치 |
|---|---|
| `Voicebox 서버에 연결할 수 없습니다` | 앱이나 컨테이너가 실행 중인지 확인합니다. Docker를 쓴다면 `VOICEBOX_URL` 을 17600 포트로 지정합니다 |
| 첫 생성이 매우 오래 걸림 | 모델(수 GB)을 내려받는 중입니다. `models --korean` 으로 상태를 확인합니다 |
| `Invalid reference audio` | 참조 음성이 너무 짧거나 손상되었습니다. 5초 이상의 깨끗한 녹음을 사용합니다 |
| 발음이 어색함 | 숫자와 영어 약어를 한글로 풀어 씁니다(예: "2026년" 대신 "이천이십육 년", "AI" 대신 "에이아이"). `--instruct` 로 속도와 말투를 조정합니다 |
| 메모리 부족으로 컨테이너가 재시작됨 | `VOICEBOX_MEMORY=12G` 로 늘리거나 `--model-size 0.6B` 를 사용합니다 |

## 사용 시 주의

- 공개하는 영상에는 "AI 음성 사용"을 표시합니다(인공지능 기본법 제31조, 유튜브 합성 콘텐츠 정책).
- 앱은 MIT 라이선스이지만, 각 음성 모델의 라이선스는 별도로 확인해야 합니다. 자세한 내용은 `docs/01-기술검토.md` 6장을 참고하세요.
- 서버 API에는 인증 기능이 없으므로 외부 네트워크에 노출하지 않습니다.

## 개발

```bash
cd client && python3 -m unittest -v test_voicebox_kr.py   # 가짜 서버로 13개 테스트
```

업스트림 버전을 올릴 때는 `deploy/UPSTREAM_COMMIT` 을 새 커밋으로 바꾸고 `./setup.sh --update` 를 실행한 뒤, 실제 서버에 대해 `health`, `init-ko`, `say` 명령을 확인합니다.
