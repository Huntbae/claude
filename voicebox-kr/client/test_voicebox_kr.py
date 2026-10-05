"""voicebox_kr 단위·통합 테스트.

업스트림 Voicebox API(/profiles, /generate, /history, /audio)를 흉내 내는
가짜 서버를 띄워 실제 HTTP 왕복으로 CLI 명령을 검증한다.
실행: python3 -m unittest -v test_voicebox_kr.py
"""

import io
import json
import tempfile
import threading
import unittest
import uuid
from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import voicebox_kr as vk

FAKE_WAV = b"RIFF\x24\x00\x00\x00WAVEfmt "


class FakeVoicebox:
    def __init__(self):
        self.profiles = []
        self.generations = {}
        self.samples = []
        self.requests = []
        self.fail_text = None  # 이 문장이 포함되면 생성 실패 처리
        self.reject_samples = False

    def handler(self):
        state = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, obj=None, raw=None, ctype="application/json"):
                body = raw if raw is not None else json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _body(self):
                n = int(self.headers.get("Content-Length", 0))
                return self.rfile.read(n)

            def do_GET(self):
                state.requests.append(("GET", self.path))
                if self.path == "/health":
                    return self._send(200, {"status": "healthy", "model_loaded": False, "gpu_available": False})
                if self.path == "/profiles":
                    return self._send(200, state.profiles)
                if self.path == "/profiles/presets/qwen_custom_voice":
                    return self._send(
                        200,
                        {"engine": "qwen_custom_voice", "voices": [
                            {"voice_id": "Vivian", "name": "Vivian", "gender": "female", "language": "zh"},
                            {"voice_id": "Sohee", "name": "Sohee", "gender": "female", "language": "ko"},
                        ]},
                    )
                if self.path == "/models/status":
                    return self._send(200, {"models": [
                        {"model_name": "qwen-custom-voice-0.6B", "display_name": "x", "downloaded": True, "size_mb": 1200},
                        {"model_name": "kokoro", "display_name": "k", "downloaded": False, "size_mb": 350},
                    ]})
                if self.path.startswith("/history/"):
                    g = state.generations[self.path.split("/")[-1]]
                    # 두 번째 조회부터 완료로 전환해 폴링 경로를 검증한다.
                    g["polls"] += 1
                    if g["status"] == "generating" and g["polls"] >= 1:
                        g["status"] = "failed" if state.fail_text and state.fail_text in g["text"] else "completed"
                        g["duration"] = 1.5
                        g["error"] = "model download failed" if g["status"] == "failed" else None
                    return self._send(200, {k: v for k, v in g.items() if k != "polls"})
                if self.path.startswith("/audio/"):
                    return self._send(200, raw=FAKE_WAV, ctype="audio/wav")
                return self._send(404, {"detail": "Not Found"})

            def do_POST(self):
                body = self._body()
                state.requests.append(("POST", self.path, body))
                if self.path == "/profiles":
                    data = json.loads(body)
                    p = dict(data, id=str(uuid.uuid4()))
                    state.profiles.append(p)
                    return self._send(200, p)
                if self.path.endswith("/samples"):
                    if state.reject_samples:
                        return self._send(400, {"detail": "Audio too short"})
                    state.samples.append(body)
                    return self._send(200, {"id": "s1"})
                if self.path == "/generate":
                    data = json.loads(body)
                    if not any(p["id"] == data["profile_id"] for p in state.profiles):
                        return self._send(404, {"detail": "Profile not found"})
                    gid = str(uuid.uuid4())
                    state.generations[gid] = {
                        "id": gid, "status": "generating", "text": data["text"],
                        "duration": 0, "error": None, "polls": 0, "payload": data,
                    }
                    g = state.generations[gid]
                    return self._send(200, {k: v for k, v in g.items() if k not in ("polls", "payload")})
                return self._send(404, {"detail": "Not Found"})

            def do_DELETE(self):
                state.requests.append(("DELETE", self.path))
                pid = self.path.split("/")[-1]
                state.profiles = [p for p in state.profiles if p["id"] != pid]
                return self._send(200, {"ok": True})

        return H


class CliTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeVoicebox()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self.fake.handler())
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = vk.main(["--url", self.url, *argv])
        return code, out.getvalue(), err.getvalue()

    def gen_payloads(self):
        return [g["payload"] for g in self.fake.generations.values()]

    def test_init_ko_creates_sohee_preset_once(self):
        code, out, _ = self.run_cli("init-ko")
        self.assertEqual(code, 0)
        self.assertEqual(len(self.fake.profiles), 1)
        p = self.fake.profiles[0]
        self.assertEqual(p["voice_type"], "preset")
        self.assertEqual(p["preset_engine"], "qwen_custom_voice")
        self.assertEqual(p["preset_voice_id"], "Sohee")
        self.assertEqual(p["language"], "ko")
        code, out, _ = self.run_cli("init-ko")
        self.assertEqual(code, 0)
        self.assertIn("이미 있습니다", out)
        self.assertEqual(len(self.fake.profiles), 1)

    def test_say_generates_korean_wav(self):
        self.run_cli("init-ko")
        out_file = self.tmp / "a" / "hello.wav"
        code, out, err = self.run_cli(
            "say", "안녕하세요. 정책 해설 채널입니다.", "-o", str(out_file),
            "--model-size", "0.6B", "--instruct", "차분하게",
        )
        self.assertEqual(code, 0, err)
        self.assertEqual(out_file.read_bytes(), FAKE_WAV)
        payload = self.gen_payloads()[0]
        self.assertEqual(payload["language"], "ko")
        self.assertEqual(payload["model_size"], "0.6B")
        self.assertEqual(payload["instruct"], "차분하게")
        self.assertEqual(payload["text"], "안녕하세요. 정책 해설 채널입니다.")
        self.assertIn("완료", err)

    def test_batch_splits_paragraphs_skips_comments_and_resumes(self):
        self.run_cli("init-ko")
        script = self.tmp / "ep01.txt"
        script.write_text(
            "# 메모: 오프닝\n첫 문단 첫 줄\n첫 문단 둘째 줄\n\n\n둘째 문단입니다.\n\n# 끝\n",
            encoding="utf-8",
        )
        code, out, err = self.run_cli("batch", str(script))
        self.assertEqual(code, 0, err)
        out_dir = self.tmp / "ep01"
        self.assertTrue((out_dir / "001.wav").exists())
        self.assertTrue((out_dir / "002.wav").exists())
        manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual([m["text"] for m in manifest], ["첫 문단 첫 줄 첫 문단 둘째 줄", "둘째 문단입니다."])
        self.assertEqual(len(self.fake.generations), 2)

        code, out, err = self.run_cli("batch", str(script), "--resume")
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.fake.generations), 2, "resume 시 재생성하면 안 됨")
        self.assertIn("건너뜀", err)

    def test_batch_failure_reports_error_and_keeps_partial_manifest(self):
        self.run_cli("init-ko")
        self.fake.fail_text = "실패"
        script = self.tmp / "ep02.txt"
        script.write_text("정상 문단\n\n실패 문단\n", encoding="utf-8")
        code, out, err = self.run_cli("batch", str(script))
        self.assertEqual(code, 1)
        self.assertIn("model download failed", err)
        manifest = json.loads((self.tmp / "ep02" / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(len(manifest), 1)

    def test_clone_requires_consent_flag(self):
        audio = self.tmp / "me.wav"
        audio.write_bytes(FAKE_WAV)
        code, _, err = self.run_cli("clone", "내목소리", "--audio", str(audio), "--text", "안녕하세요")
        self.assertEqual(code, 1)
        self.assertIn("--i-have-consent", err)
        self.assertEqual(self.fake.profiles, [])

    def test_clone_uploads_sample_multipart(self):
        audio = self.tmp / "me.wav"
        audio.write_bytes(FAKE_WAV)
        code, out, err = self.run_cli(
            "clone", "내목소리", "--audio", str(audio), "--text", "안녕하세요 반갑습니다", "--i-have-consent"
        )
        self.assertEqual(code, 0, err)
        p = self.fake.profiles[0]
        self.assertEqual((p["voice_type"], p["language"], p["default_engine"]), ("cloned", "ko", "qwen"))
        body = self.fake.samples[0]
        self.assertIn("안녕하세요 반갑습니다".encode(), body)
        self.assertIn(FAKE_WAV, body)
        self.assertIn(b'name="reference_text"', body)
        self.assertIn(b'name="file"; filename="me.wav"', body)

    def test_clone_rolls_back_profile_when_sample_rejected(self):
        self.fake.reject_samples = True
        audio = self.tmp / "me.wav"
        audio.write_bytes(FAKE_WAV)
        code, _, err = self.run_cli(
            "clone", "내목소리", "--audio", str(audio), "--text", "짧음", "--i-have-consent"
        )
        self.assertEqual(code, 1)
        self.assertIn("Audio too short", err)
        self.assertEqual(self.fake.profiles, [], "실패 시 빈 프로필이 남으면 안 됨")

    def test_non_korean_engine_rejected_before_request(self):
        self.run_cli("init-ko")
        with self.assertRaises(SystemExit):
            # argparse choices 에서 차단
            with redirect_stderr(io.StringIO()):
                vk.main(["--url", self.url, "say", "안녕", "--engine", "kokoro"])
        with self.assertRaises(vk.VoiceboxError):
            vk.check_engine("tada")
        self.assertEqual(self.fake.generations, {})

    def test_unknown_profile_lists_available(self):
        self.run_cli("init-ko")
        code, _, err = self.run_cli("say", "안녕", "-p", "없는프로필", "-o", str(self.tmp / "x.wav"))
        self.assertEqual(code, 1)
        self.assertIn("소희 (한국어 기본)", err)

    def test_presets_and_models_listing(self):
        code, out, _ = self.run_cli("presets")
        self.assertIn("Sohee", out)
        self.assertIn("<- 한국어", out)
        code, out, _ = self.run_cli("models", "--korean")
        self.assertIn("qwen-custom-voice-0.6B", out)
        self.assertNotIn("kokoro", out)

    def test_connection_error_message(self):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = vk.main(["--url", "http://127.0.0.1:9", "health"])
        self.assertEqual(code, 1)
        self.assertIn("17600", err.getvalue())


class SplitTest(unittest.TestCase):
    def test_split_segments(self):
        text = "가\n나\n\n# 주석\n\n다\r\n\r\n"
        self.assertEqual(vk.split_segments(text), ["가 나", "다"])

    def test_split_empty(self):
        self.assertEqual(vk.split_segments("# only\n\n   \n"), [])


if __name__ == "__main__":
    unittest.main()
