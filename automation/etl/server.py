from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess, json

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        r = subprocess.run(["python", "run_etl.py"], cwd="/app",
                           capture_output=True, text=True)
        body = json.dumps({"ok": r.returncode == 0,
                           "stdout": r.stdout[-5000:],
                           "stderr": r.stderr[-5000:]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

HTTPServer(("0.0.0.0", 8000), H).serve_forever()