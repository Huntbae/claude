#!/bin/bash
# DiffusionBear 설치 및 설치된 모델 점검 (macOS 전용, 읽기 전용)
#
# 사용법: bash check_install.sh
# 아무것도 설치하거나 지우지 않습니다. 결과를 복사해 Claude에게 붙여넣으면 분석해 줍니다.

APP="${DIFFUSIONBEAR_APP:-/Applications/DiffusionBear.app}"
SUPPORT="$HOME/Library/Application Support/DiffusionBear"
HF_HUB="$HOME/.cache/huggingface/hub"
EXPECTED_VERSION="0.4.2"

line() { printf '%s\n' "------------------------------------------------------------"; }
human() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

line
echo "[1] 시스템"
line
if [ "$(uname)" = "Darwin" ]; then
  echo "macOS      : $(sw_vers -productVersion 2>/dev/null) (필요: 26.2 이상)"
  echo "칩         : $(sysctl -n machdep.cpu.brand_string 2>/dev/null) / $(uname -m)"
  mem=$(sysctl -n hw.memsize 2>/dev/null)
  [ -n "$mem" ] && echo "메모리     : $((mem / 1073741824)) GB (권장: 16GB 이상)"
else
  echo "macOS가 아닙니다($(uname)). DiffusionBear는 Apple Silicon Mac 전용입니다."
fi
echo "디스크 여유: $(df -h "$HOME" | awk 'NR==2{print $4}')"

line
echo "[2] 앱 설치"
line
if [ -d "$APP" ]; then
  ver=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)
  echo "설치 위치  : $APP"
  echo "앱 버전    : ${ver:-확인 불가} (최신: $EXPECTED_VERSION)"
  [ -n "$ver" ] && [ "$ver" != "$EXPECTED_VERSION" ] && echo "  -> 최신 버전이 아닙니다. 업데이트를 권장합니다."
  echo "앱 크기    : $(human "$APP")"
  if xattr "$APP" 2>/dev/null | grep -q com.apple.quarantine; then
    echo "격리 속성  : 남아 있음 -> 첫 실행이 차단될 수 있습니다. xattr -cr \"$APP\" 실행 필요"
  else
    echo "격리 속성  : 없음 (정상)"
  fi
  if codesign --verify --deep "$APP" >/dev/null 2>&1; then
    echo "코드 서명  : 무결성 정상 (ad-hoc 서명)"
  else
    echo "코드 서명  : 검증 실패 -> 앱 파일이 손상/변경되었을 수 있습니다. 재설치 권장"
  fi
  case "$APP" in /Volumes/*) echo "  -> 외장 볼륨에서 실행 중입니다. /Applications로 옮기세요(멈춤 원인)." ;; esac
else
  echo "설치되지 않음: $APP 가 없습니다."
fi

PY=""
for cand in "$APP/Contents/Resources/venv/bin/python" "$(command -v python3 2>/dev/null)"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then PY="$cand"; break; fi
done

MODELS_REPORT_PY=$(cat <<'PYEOF'
import json, sys
try:
    items = json.load(sys.stdin)
except Exception as e:
    print("모델 목록을 읽지 못했습니다:", e)
    sys.exit(0)
if isinstance(items, dict):
    items = items.get("items") or items.get("models") or []

def gb(n):
    return "%.1f GB" % ((n or 0) / 1024 ** 3)

def label(m):
    return m.get("label") or m.get("name") or m.get("id")

inst = [m for m in items if m.get("installed")]
rest = [m for m in items if not m.get("installed")]
total = sum(m.get("disk_usage_bytes") or 0 for m in inst)
print()
print("설치됨 (%d개, 합계 %s)" % (len(inst), gb(total)))
for m in inst:
    print("  [O] %-40s %9s   id=%s" % (label(m), gb(m.get("disk_usage_bytes")), m.get("id")))
print()
print("미설치 (%d개, 처음 사용할 때 내려받음)" % len(rest))
for m in rest:
    print("  [ ] %-40s             id=%s" % (label(m), m.get("id")))
PYEOF
)

line
echo "[3] 앱 실행 상태 및 모델 목록 (앱 API 기준)"
line
PORT=""
for i in 0 1 2 3 4 5 6 7 8 9; do
  p=$((8001 + i * 1024))
  if curl -s --max-time 2 "http://127.0.0.1:$p/api/version" 2>/dev/null | grep -qi "version"; then
    PORT=$p; break
  fi
done

if [ -z "$PORT" ]; then
  echo "앱이 실행 중이 아닙니다. 앱을 켠 뒤 다시 실행하면 정확한 모델 목록이 나옵니다."
  echo "(아래 [4]의 디스크 검사 결과는 앱 실행 여부와 관계없이 유효합니다.)"
elif [ -z "$PY" ]; then
  echo "앱 실행 중(포트 $PORT). JSON 분석용 Python을 찾지 못해 원본을 출력합니다."
  curl -s --max-time 30 "http://127.0.0.1:$PORT/api/models"
  echo
else
  echo "앱 실행 중: http://127.0.0.1:$PORT  ($(curl -s --max-time 2 "http://127.0.0.1:$PORT/api/version"))"
  curl -s --max-time 60 "http://127.0.0.1:$PORT/api/models" | "$PY" -I -c "$MODELS_REPORT_PY"
fi

line
echo "[4] 디스크에 있는 모델 파일 (앱 실행 여부와 무관)"
line
STORE="$SUPPORT"
if [ -f "$SUPPORT/store_path" ]; then
  custom=$(head -n1 "$SUPPORT/store_path")
  echo "저장소 위치 변경됨(store_path): $custom"
  [ -d "$custom" ] && STORE="$custom" || echo "  -> 지정된 위치가 없습니다(외장 드라이브 미연결?). 기본 위치를 검사합니다."
fi
DATA="$STORE"
[ "$(basename "$STORE")" != "data" ] && DATA="$STORE/data"
echo "앱 데이터  : $DATA ($(human "$DATA"))"

# 폴더 하나의 상태: 심볼릭 링크 대상, 미완료 다운로드 파일 수, 가중치 파일 수, 가장 큰 파일
detail() {
  local d="$1" real="$1" note=""
  if [ -L "$d" ]; then
    real=$(cd "$d" 2>/dev/null && pwd -P)
    if [ -z "$real" ]; then
      printf '      -> 링크 대상 없음(끊어진 링크): %s\n' "$(readlink "$d")"
      return
    fi
    printf '      -> 링크: %s (%s)\n' "$real" "$(du -sh "$real/" 2>/dev/null | awk '{print $1}')"
  fi
  local inc wts big
  inc=$(find -L "$real" \( -name '*.incomplete' -o -name '*.part' \) 2>/dev/null | wc -l | tr -d ' ')
  wts=$(find -L "$real" \( -name '*.safetensors' -o -name '*.npz' -o -name '*.gguf' \) 2>/dev/null | wc -l | tr -d ' ')
  big=$(find -L "$real" -type f -size +1M -exec ls -lhL {} + 2>/dev/null | sort -k5 -h | tail -n1 | awk '{print $5}')
  [ "$inc" != 0 ] && note="미완료 다운로드 파일 ${inc}개 -> 다운로드가 중단된 상태"
  printf '      가중치 파일 %s개, 가장 큰 파일: %s\n' "$wts" "${big:-없음}"
  [ -n "$note" ] && printf '      [주의] %s\n' "$note"
  [ "$wts" = 0 ] && printf '      [주의] 가중치 파일이 없습니다 -> 설치가 끝나지 않았거나 빈 폴더입니다\n'
}

found=0
for sub in models SDXL lora_files; do
  if [ -d "$DATA/$sub" ]; then
    for d in "$DATA/$sub"/*; do
      [ -e "$d" ] || [ -L "$d" ] || continue
      printf '  %-12s %-50s %8s\n' "$sub" "$(basename "$d")" "$(du -shL "$d" 2>/dev/null | awk '{print $1}')"
      [ "$sub" != lora_files ] && detail "$d"
      found=1
    done
  fi
done
[ "$found" = 0 ] && echo "  (앱 데이터 폴더에 모델 없음)"

echo
echo "Hugging Face 캐시: $HF_HUB"
if [ -d "$HF_HUB" ]; then
  hf=0
  for d in "$HF_HUB"/models--*; do
    [ -d "$d" ] || continue
    repo=$(basename "$d" | sed 's/^models--//; s/--/\//')
    printf '  %-60s %8s\n' "$repo" "$(human "$d")"
    inc=$(find "$d/blobs" -name '*.incomplete' 2>/dev/null | wc -l | tr -d ' ')
    [ "$inc" != 0 ] && printf '      [주의] 미완료 다운로드 파일 %s개 -> 다운로드가 중단된 상태\n' "$inc"
    [ -z "$(find "$d/blobs" -type f -size +1M 2>/dev/null | head -n1)" ] && printf '      [주의] 실제 가중치가 없습니다(목록 정보만 있음)\n'
    hf=1
  done
  [ "$hf" = 0 ] && echo "  (모델 없음)"
  echo "  합계: $(human "$HF_HUB")"
  echo "  참고: 이 캐시는 다른 AI 앱과 공유될 수 있어, DiffusionBear용이 아닌 모델도 보일 수 있습니다."
else
  echo "  (캐시 폴더 없음)"
fi

line
echo "[5] 최근 오류 로그"
line
LOG="$HOME/Library/Application Support/DiffusionBear/Logs/backend.log"
if [ -f "$LOG" ]; then
  errs=$(grep -iE "error|traceback|exception" "$LOG" | tail -n 5)
  [ -n "$errs" ] && echo "$errs" || echo "최근 오류 없음 ($LOG)"
else
  echo "로그 없음 (앱을 한 번도 실행하지 않았을 수 있습니다)"
fi
line
