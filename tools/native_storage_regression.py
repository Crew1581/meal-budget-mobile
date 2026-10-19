"""Native P1: только новый изолированный MEAL10StorageRegression AVD и synthetic HTTP."""

import argparse
import base64
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import threading
import xml.etree.ElementTree as ET

APP = "com.example.meal_budget_mobile"
PREFS = "shared_prefs/FlutterSecureStorage.xml"
URL = "http://10.0.2.2:8765"
KEY = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_installation_" + base64.urlsafe_b64encode(URL.encode()).decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--adb", type=Path, default=Path.home() / "Android/Sdk/platform-tools/adb")
    args = parser.parse_args()

    def adb(*command, data=None):
        result = subprocess.run([str(args.adb), "-s", args.device, *command], input=data, capture_output=True, check=False, timeout=30)
        if result.returncode:
            raise RuntimeError("ADB test operation failed; private output suppressed")
        return result.stdout

    avd = adb("emu", "avd", "name").decode().splitlines()[0]
    if not avd.startswith("MEAL10StorageRegression"):
        raise RuntimeError("Нужен отдельный AVD с именем MEAL10StorageRegression*. Пользовательские AVD запрещены.")
    if adb("shell", "pm", "list", "packages", APP).strip():
        raise RuntimeError("AVD должен быть чистым: приложение уже установлено. Данные не тронуты.")

    counts = {"registrations": 0, "generation_posts": 0}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # No headers, bodies, credentials or raw exceptions in logs.

        def send_json(self, status, value):
            body = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            self.send_json(200, counts)

        def do_POST(self):
            if self.path == "/v1/installations":
                counts["registrations"] += 1
                self.send_json(201, {
                    "installation_id": "00000000-0000-4000-8000-000000000002",
                    "token": "synthetic-native-regression-not-a-real-credential",
                    "token_type": "Bearer",
                })
            else:
                counts["generation_posts"] += 1
                self.send_json(503, {"detail": {"code": "worker_unavailable", "message": "Synthetic", "metadata": None}})

    server = ThreadingHTTPServer(("127.0.0.1", 8765), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def run_flutter(phase):
        result = subprocess.run([
            "flutter", "test", "integration_test/native_storage_test.dart", "-d", args.device,
            "--no-uninstall",
            "--dart-define=NATIVE_STORAGE_REGRESSION=true",
        ], capture_output=True, text=True, timeout=600)
        # Plugin 10.3.4 itself prints native diagnostics; never copy its raw
        # exception/SharedPreferences output into reports or retained test logs.
        if result.returncode or "All tests passed!" not in result.stdout:
            raise RuntimeError(f"Native {phase} failed; raw output suppressed")
        print(f"Native {phase}: passed", flush=True)

    def prefs():
        return ET.fromstring(adb("shell", "run-as", APP, "cat", PREFS))

    try:
        run_flutter("seed")
        assert counts == {"registrations": 1, "generation_posts": 0}, "Неверные счётчики seed"
        adb("shell", "am", "force-stop", APP)
        root = prefs()
        entry = root.find(f"string[@name='{KEY}']")
        assert entry is not None, "Синтетическая запись не найдена"
        # Preserve valid Base64, IV and size; break the AES-GCM authentication tag.
        damaged = bytearray(base64.b64decode(entry.text))
        damaged[-1] ^= 1
        entry.text = base64.b64encode(damaged).decode()
        corrupted = ET.tostring(root, encoding="utf-8", xml_declaration=True)
        adb("shell", "run-as", APP, "sh", "-c", f"'cat > {PREFS}'", data=corrupted)
        run_flutter("corrupt-read-after-force-stop")
        adb("shell", "am", "force-stop", APP)
        after = prefs()
        assert ET.tostring(after) == ET.tostring(root), "Storage был изменён автоматически"
        assert counts == {"registrations": 1, "generation_posts": 0}, "После повреждения возник лишний HTTP POST"
        print("Native final: registrations 1 → 1; generation POST 0; повреждённая запись сохранена", flush=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Only our fixed diagnostics, never raw subprocess/storage exceptions.
        if isinstance(error, (RuntimeError, AssertionError)):
            raise SystemExit(str(error)) from None
        raise SystemExit("Native regression failed; private diagnostic output suppressed") from None
