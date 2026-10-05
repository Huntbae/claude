#!/usr/bin/env bash
# Voicebox 한국어 운영 구성 설치 스크립트 (macOS / Linux / Windows WSL2)
#
#   ./setup.sh              업스트림 소스 받기 + 이미지 빌드 + 기동
#   ./setup.sh --gpu        NVIDIA GPU 사용
#   ./setup.sh --update     UPSTREAM_COMMIT 에 적힌 커밋으로 소스 갱신 후 재빌드
#   ./setup.sh --no-start   소스만 받고 빌드/기동은 하지 않음
set -euo pipefail

cd "$(dirname "$0")"
REPO_URL="https://github.com/jamiepine/voicebox.git"
COMMIT="$(tr -d '[:space:]' < UPSTREAM_COMMIT)"
GPU=0; UPDATE=0; START=1
for arg in "$@"; do
  case "$arg" in
    --gpu) GPU=1 ;;
    --update) UPDATE=1 ;;
    --no-start) START=0 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "알 수 없는 옵션: $arg" >&2; exit 2 ;;
  esac
done

command -v git >/dev/null || { echo "git 이 필요합니다." >&2; exit 1; }

if [ ! -d upstream/.git ]; then
  echo "업스트림 소스를 받는 중 ($COMMIT)..."
  git init -q upstream
  git -C upstream remote add origin "$REPO_URL"
  UPDATE=1
fi
if [ "$UPDATE" = 1 ]; then
  git -C upstream fetch -q --depth 1 origin "$COMMIT"
  git -C upstream checkout -q --detach FETCH_HEAD
fi
echo "업스트림 커밋: $(git -C upstream rev-parse --short HEAD)"
mkdir -p output

[ "$START" = 1 ] || exit 0
command -v docker >/dev/null || { echo "Docker Desktop(또는 Docker Engine)을 설치한 뒤 다시 실행하세요." >&2; exit 1; }

FILES=(-f docker-compose.kr.yml)
[ "$GPU" = 1 ] && FILES+=(-f docker-compose.nvidia.yml)

echo "이미지 빌드 및 기동 (최초 빌드는 10~30분 걸릴 수 있습니다)..."
docker compose "${FILES[@]}" up -d --build

PORT="${VOICEBOX_PORT:-17600}"
echo -n "서버 준비 대기"
for _ in $(seq 1 90); do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null; then
    echo
    echo "완료. 웹 UI: http://127.0.0.1:${PORT}"
    echo "클라이언트: export VOICEBOX_URL=http://127.0.0.1:${PORT}"
    exit 0
  fi
  echo -n "."; sleep 2
done
echo
echo "서버가 아직 응답하지 않습니다. 로그 확인: docker compose -f docker-compose.kr.yml logs -f" >&2
exit 1
