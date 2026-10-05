#!/usr/bin/env python3
"""voicebox-kr: 한국어 내레이션용 Voicebox REST API 클라이언트.

Voicebox(https://github.com/jamiepine/voicebox) 로컬 서버에 연결해
한국어 음성 프로필을 만들고, 대본을 음성 파일(WAV)로 생성한다.
표준 라이브러리만 사용하므로 별도 설치가 필요 없다(Python 3.9 이상).

서버 주소는 --url 옵션 또는 VOICEBOX_URL 환경변수로 지정한다.
  - 데스크톱 앱 기본값: http://127.0.0.1:17493
  - 이 저장소의 Docker 구성:  http://127.0.0.1:17600
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

DEFAULT_URL = "http://127.0.0.1:17493"

# 업스트림 backend/backends/__init__.py 의 모델별 languages 목록 기준.
# 한국어(ko)를 지원하는 엔진만 허용한다.
KOREAN_ENGINES = {
    "qwen": "Qwen3-TTS (음성 복제)",
    "qwen_custom_voice": "Qwen CustomVoice (프리셋 음성)",
    "chatterbox": "Chatterbox Multilingual (음성 복제)",
}
NON_KOREAN_ENGINES = {"luxtts", "chatterbox_turbo", "tada", "kokoro"}
KOREAN_MODELS = {
    "qwen-tts-1.7B",
    "qwen-tts-0.6B",
    "qwen-custom-voice-1.7B",
    "qwen-custom-voice-0.6B",
    "chatterbox-tts",
}

# Qwen CustomVoice 에 내장된 한국어 프리셋 화자
KOREAN_PRESET_ENGINE = "qwen_custom_voice"
KOREAN_PRESET_VOICE_ID = "Sohee"
KOREAN_PRESET_PROFILE_NAME = "소희 (한국어 기본)"

TERMINAL_STATUSES = {"completed", "failed"}


class VoiceboxError(RuntimeError):
    """서버 오류 또는 사용 오류. CLI 에서는 메시지만 출력하고 종료 코드 1."""


# ---------------------------------------------------------------- HTTP


class VoiceboxClient:
    def __init__(self, base_url: str, timeout: float = 60.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def _request(self, method, path, body=None, headers=None, raw=False):
        url = f"{self.base_url}{path}"
        req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                data = resp.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")
            try:
                detail = json.loads(detail).get("detail", detail)
            except (ValueError, AttributeError):
                pass
            raise VoiceboxError(f"{method} {path} 실패 (HTTP {e.code}): {detail}") from None
        except urllib.error.URLError as e:
            raise VoiceboxError(
                f"Voicebox 서버에 연결할 수 없습니다 ({self.base_url}): {e.reason}\n"
                "  - 데스크톱 앱이 실행 중인지, 또는 Docker 컨테이너가 올라와 있는지 확인하세요.\n"
                "  - Docker 구성을 쓰는 경우 VOICEBOX_URL=http://127.0.0.1:17600 으로 지정하세요."
            ) from None
        if raw:
            return data
        return json.loads(data.decode("utf-8")) if data else None

    def get(self, path):
        return self._request("GET", path)

    def post_json(self, path, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        return self._request("POST", path, body, {"Content-Type": "application/json"})

    def post_multipart(self, path, fields: dict, file_field: str, file_path: Path):
        boundary = uuid.uuid4().hex
        parts = []
        for name, value in fields.items():
            parts.append(
                f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'.encode()
                + str(value).encode("utf-8")
                + b"\r\n"
            )
        filename = urllib.parse.quote(file_path.name)
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; '
            f'filename="{filename}"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode()
            + file_path.read_bytes()
            + b"\r\n"
        )
        parts.append(f"--{boundary}--\r\n".encode())
        return self._request(
            "POST",
            path,
            b"".join(parts),
            {"Content-Type": f"multipart/form-data; boundary={boundary}"},
        )

    def download(self, path) -> bytes:
        return self._request("GET", path, raw=True)

    # ---------------------------------------------------------- domain

    def profiles(self):
        return self.get("/profiles")

    def find_profile(self, name_or_id: str):
        key = name_or_id.strip().casefold()
        for p in self.profiles():
            if p["id"] == name_or_id or p["name"].casefold() == key:
                return p
        return None

    def require_profile(self, name_or_id: str):
        profile = self.find_profile(name_or_id)
        if not profile:
            names = ", ".join(p["name"] for p in self.profiles()) or "(없음)"
            raise VoiceboxError(
                f"프로필 '{name_or_id}' 을(를) 찾을 수 없습니다. 사용 가능한 프로필: {names}\n"
                "  - 처음이라면 'init-ko' 로 한국어 기본 프로필을 만드세요."
            )
        return profile

    def generate(self, payload: dict, poll_interval: float, timeout: float, on_status=None):
        gen = self.post_json("/generate", payload)
        gen_id = gen["id"]
        deadline = time.monotonic() + timeout
        last_status = None
        while True:
            status = gen.get("status") or "completed"
            if status != last_status and on_status:
                on_status(status)
            last_status = status
            if status in TERMINAL_STATUSES:
                break
            if time.monotonic() > deadline:
                raise VoiceboxError(
                    f"생성 대기 시간({timeout:.0f}초)을 초과했습니다. 생성 ID: {gen_id}\n"
                    "  - 첫 실행은 모델 다운로드(수 GB) 때문에 오래 걸릴 수 있습니다. "
                    "--timeout 을 늘려 다시 실행하세요."
                )
            time.sleep(poll_interval)
            gen = self.get(f"/history/{gen_id}")
        if status == "failed":
            raise VoiceboxError(f"음성 생성 실패 (ID {gen_id}): {gen.get('error') or '원인 미상'}")
        return gen, self.download(f"/audio/{gen_id}")


# ---------------------------------------------------------------- text


def split_segments(text: str) -> list[str]:
    """대본을 빈 줄 기준 문단으로 나눈다. '#' 으로 시작하는 줄은 메모로 보고 제외한다."""
    lines = [ln for ln in text.splitlines() if not ln.lstrip().startswith("#")]
    blocks = re.split(r"\n\s*\n", "\n".join(lines))
    segments = []
    for block in blocks:
        joined = " ".join(ln.strip() for ln in block.splitlines() if ln.strip())
        if joined:
            segments.append(joined)
    return segments


def check_engine(engine: str | None) -> None:
    if engine and engine in NON_KOREAN_ENGINES:
        supported = ", ".join(f"{k}({v})" for k, v in KOREAN_ENGINES.items())
        raise VoiceboxError(f"엔진 '{engine}' 은(는) 한국어를 지원하지 않습니다. 사용 가능: {supported}")


def build_payload(profile: dict, text: str, args) -> dict:
    check_engine(args.engine)
    payload = {
        "profile_id": profile["id"],
        "text": text,
        "language": args.language,
        "max_chunk_chars": args.max_chunk_chars,
        "crossfade_ms": args.crossfade_ms,
        "normalize": True,
    }
    if args.engine:
        payload["engine"] = args.engine
    if args.model_size:
        payload["model_size"] = args.model_size
    if args.instruct:
        payload["instruct"] = args.instruct
    if args.seed is not None:
        payload["seed"] = args.seed
    return payload


def status_printer(prefix=""):
    labels = {
        "generating": "생성 중",
        "loading_model": "모델 로딩 중 (첫 실행 시 다운로드 포함, 수 분 소요 가능)",
        "completed": "완료",
        "failed": "실패",
    }

    def _print(status):
        print(f"{prefix}상태: {labels.get(status, status)}", file=sys.stderr)

    return _print


# ---------------------------------------------------------------- commands


def cmd_health(client, args):
    print(json.dumps(client.get("/health"), ensure_ascii=False, indent=2))


def cmd_profiles(client, args):
    profiles = client.profiles()
    if not profiles:
        print("등록된 프로필이 없습니다. 'init-ko' 또는 'clone' 으로 만드세요.")
        return
    for p in profiles:
        engine = p.get("preset_engine") or p.get("default_engine") or "qwen"
        print(f"{p['name']}\t[{p.get('voice_type', 'cloned')}/{engine}]\tlang={p['language']}\tid={p['id']}")


def cmd_presets(client, args):
    data = client.get(f"/profiles/presets/{KOREAN_PRESET_ENGINE}")
    for v in data.get("voices", []):
        mark = "  <- 한국어" if v.get("language") == "ko" else ""
        print(f"{v['voice_id']}\t{v['gender']}\t{v['language']}{mark}")


def cmd_init_ko(client, args):
    existing = client.find_profile(KOREAN_PRESET_PROFILE_NAME)
    if existing:
        print(f"이미 있습니다: {existing['name']} (id={existing['id']})")
        return
    profile = client.post_json(
        "/profiles",
        {
            "name": KOREAN_PRESET_PROFILE_NAME,
            "description": "Qwen CustomVoice 내장 한국어 여성 화자. 참조 음성 없이 바로 사용 가능.",
            "language": "ko",
            "voice_type": "preset",
            "preset_engine": KOREAN_PRESET_ENGINE,
            "preset_voice_id": KOREAN_PRESET_VOICE_ID,
            "default_engine": KOREAN_PRESET_ENGINE,
        },
    )
    print(f"생성 완료: {profile['name']} (id={profile['id']})")


def cmd_clone(client, args):
    if not args.i_have_consent:
        raise VoiceboxError(
            "음성 복제는 본인 또는 명시적으로 동의한 화자의 음성만 허용됩니다.\n"
            "  - 동의를 확보했다면 --i-have-consent 옵션을 추가하세요.\n"
            "  - 근거: 부정경쟁방지법 제2조제1호타목(타인 음성의 무단 영업적 사용 금지)"
        )
    check_engine(args.engine)
    audio = Path(args.audio)
    if not audio.is_file():
        raise VoiceboxError(f"참조 음성 파일이 없습니다: {audio}")
    if client.find_profile(args.name):
        raise VoiceboxError(f"같은 이름의 프로필이 이미 있습니다: {args.name}")
    profile = client.post_json(
        "/profiles",
        {
            "name": args.name,
            "description": args.description,
            "language": "ko",
            "voice_type": "cloned",
            "default_engine": args.engine,
        },
    )
    try:
        client.post_multipart(
            f"/profiles/{profile['id']}/samples",
            {"reference_text": args.text},
            "file",
            audio,
        )
    except VoiceboxError:
        # 샘플 업로드가 실패하면 빈 프로필이 남지 않도록 정리한다.
        try:
            client._request("DELETE", f"/profiles/{profile['id']}")
        except VoiceboxError:
            pass
        raise
    print(f"복제 프로필 생성 완료: {profile['name']} (id={profile['id']}, 엔진={args.engine})")


def _read_text(args) -> str:
    if args.file:
        return Path(args.file).read_text(encoding="utf-8")
    if args.text:
        return args.text
    if not sys.stdin.isatty():
        return sys.stdin.read()
    raise VoiceboxError("읽을 문장이 없습니다. 문장을 인자로 주거나 --file 을 지정하세요.")


def cmd_say(client, args):
    text = " ".join(split_segments(_read_text(args)))
    if not text:
        raise VoiceboxError("읽을 문장이 비어 있습니다.")
    profile = client.require_profile(args.profile)
    gen, audio = client.generate(
        build_payload(profile, text, args), args.poll_interval, args.timeout, status_printer()
    )
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(audio)
    print(f"저장: {out} ({gen.get('duration') or 0:.1f}초)")


def cmd_batch(client, args):
    script = Path(args.script)
    segments = split_segments(script.read_text(encoding="utf-8"))
    if not segments:
        raise VoiceboxError(f"대본에 읽을 문단이 없습니다: {script}")
    profile = client.require_profile(args.profile)
    out_dir = Path(args.out_dir or script.with_suffix(""))
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = out_dir / "manifest.json"
    manifest = []
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    done = {m["index"]: m for m in manifest if m.get("text") in segments}

    total = len(segments)
    print(f"대본 {total}개 문단 -> {out_dir}", file=sys.stderr)
    results = []
    for i, seg in enumerate(segments, 1):
        wav = out_dir / f"{i:03d}.wav"
        prev = done.get(i)
        if args.resume and prev and prev.get("text") == seg and wav.exists():
            print(f"[{i}/{total}] 건너뜀(이미 생성됨)", file=sys.stderr)
            results.append(prev)
            continue
        gen, audio = client.generate(
            build_payload(profile, seg, args),
            args.poll_interval,
            args.timeout,
            status_printer(f"[{i}/{total}] "),
        )
        wav.write_bytes(audio)
        results.append(
            {
                "index": i,
                "file": wav.name,
                "duration": gen.get("duration"),
                "generation_id": gen["id"],
                "text": seg,
            }
        )
        # 중간에 끊겨도 --resume 으로 이어서 만들 수 있도록 매 문단마다 기록한다.
        manifest_path.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")

    manifest_path.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    total_sec = sum(r.get("duration") or 0 for r in results)
    print(f"완료: {len(results)}개 파일, 총 {total_sec:.1f}초, 목록 {manifest_path}")


def cmd_models(client, args):
    data = client.get("/models/status")
    for m in data.get("models", []):
        name = m["model_name"]
        ko = name in KOREAN_MODELS
        if args.korean and not ko:
            continue
        if m.get("loaded"):
            state = "로드됨"
        elif m.get("downloading"):
            state = "다운로드 중"
        elif m.get("downloaded"):
            state = "다운로드됨"
        else:
            state = "미다운로드"
        size = f"{m['size_mb'] / 1024:.1f}GB" if m.get("size_mb") else "-"
        print(f"{name}\t{state}\t{size}\t{'한국어 TTS' if ko else ''}")


# ---------------------------------------------------------------- cli


def _add_generation_options(p):
    p.add_argument("--profile", "-p", default=KOREAN_PRESET_PROFILE_NAME, help="프로필 이름 또는 ID")
    p.add_argument("--engine", choices=sorted(KOREAN_ENGINES), help="엔진 강제 지정(기본: 프로필 설정)")
    p.add_argument("--model-size", choices=["1.7B", "0.6B"], help="Qwen 모델 크기. CPU 환경이면 0.6B 권장")
    p.add_argument("--instruct", help="말투 지시(Qwen 계열). 예: '차분하고 또박또박하게'")
    p.add_argument("--seed", type=int, help="같은 결과를 재현하고 싶을 때 고정")
    p.add_argument("--language", default="ko", help="언어 코드(기본 ko)")
    p.add_argument("--max-chunk-chars", type=int, default=800, help="긴 글 자동 분할 단위(100~5000)")
    p.add_argument("--crossfade-ms", type=int, default=50, help="분할 구간 사이 크로스페이드(ms)")
    p.add_argument("--timeout", type=float, default=1800, help="문단당 최대 대기 시간(초)")
    p.add_argument("--poll-interval", type=float, default=2.0, help=argparse.SUPPRESS)


def build_parser():
    parser = argparse.ArgumentParser(
        prog="voicebox_kr",
        description="Voicebox 한국어 내레이션 클라이언트",
    )
    parser.add_argument("--url", default=os.environ.get("VOICEBOX_URL", DEFAULT_URL), help="Voicebox 서버 주소")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("health", help="서버 상태 확인").set_defaults(func=cmd_health)
    sub.add_parser("profiles", help="음성 프로필 목록").set_defaults(func=cmd_profiles)
    sub.add_parser("presets", help="프리셋 화자 목록(한국어 표시)").set_defaults(func=cmd_presets)
    sub.add_parser("init-ko", help="한국어 기본 프로필(소희) 생성").set_defaults(func=cmd_init_ko)

    p = sub.add_parser("models", help="모델 다운로드 상태")
    p.add_argument("--korean", action="store_true", help="한국어 지원 모델만 표시")
    p.set_defaults(func=cmd_models)

    p = sub.add_parser("clone", help="참조 음성으로 한국어 복제 프로필 생성")
    p.add_argument("name", help="새 프로필 이름")
    p.add_argument("--audio", required=True, help="참조 음성 파일(wav/mp3/m4a 등, 5~30초 권장)")
    p.add_argument("--text", required=True, help="참조 음성에서 실제로 말한 문장(정확할수록 품질 향상)")
    p.add_argument("--engine", default="qwen", choices=["qwen", "chatterbox"], help="복제 엔진")
    p.add_argument("--description", default=None)
    p.add_argument("--i-have-consent", action="store_true", help="화자 본인 또는 화자의 명시적 동의를 확보했음을 확인")
    p.set_defaults(func=cmd_clone)

    p = sub.add_parser("say", help="문장 하나를 음성 파일로 생성")
    p.add_argument("text", nargs="?", help="읽을 문장(생략 시 --file 또는 표준입력)")
    p.add_argument("--file", "-f", help="문장을 읽어올 텍스트 파일")
    p.add_argument("--out", "-o", default="output.wav", help="저장할 파일 경로")
    _add_generation_options(p)
    p.set_defaults(func=cmd_say)

    p = sub.add_parser("batch", help="대본 파일을 문단별 음성 파일로 일괄 생성")
    p.add_argument("script", help="대본 파일(.txt/.md). 빈 줄로 문단 구분, '#' 줄은 제외")
    p.add_argument("--out-dir", "-o", help="출력 폴더(기본: 대본 파일명 폴더)")
    p.add_argument("--resume", action="store_true", help="이미 생성된 문단은 건너뛰기")
    _add_generation_options(p)
    p.set_defaults(func=cmd_batch)
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    client = VoiceboxClient(args.url)
    try:
        args.func(client, args)
    except VoiceboxError as e:
        print(f"오류: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\n중단되었습니다. batch 는 --resume 으로 이어서 실행할 수 있습니다.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
