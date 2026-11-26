from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess, json

def run(cmd):
    return subprocess.run(cmd, cwd="/app", capture_output=True, text=True)

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        etl = run(["python", "run_etl.py"])
        out, err, ok = etl.stdout, etl.stderr, etl.returncode == 0
        if ok:  # build ames_story.xlsx only after all checks pass
            wb = run(["python", "make_workbook.py"])
            out += "\n--- make_workbook ---\n" + wb.stdout
            err += wb.stderr
            ok = wb.returncode == 0
        body = json.dumps({"ok": ok, "stdout": out[-5000:], "stderr": err[-5000:]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

HTTPServer(("0.0.0.0", 8000), H).serve_forever()