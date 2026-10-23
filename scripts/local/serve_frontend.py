"""Static server for LOCAL development (started by scripts/start-local.ps1).

Like `python -m http.server`, but: binds to 127.0.0.1 only, sends `Cache-Control: no-store` (edited JS/CSS is never
stale), forces correct MIME types for ES modules (the Windows registry can map .js to text/plain), and refuses
dot-paths such as /.git or /.local. Standard library only.
Usage: python scripts/local/serve_frontend.py <repo root> [port] [log file]
"""
import functools
import http.server
import sys

ROOT = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 5173
HOST = "127.0.0.1"
if len(sys.argv) > 3:   # started in the background by start-local.ps1: log requests and errors to a file
    sys.stdout = sys.stderr = open(sys.argv[3], "a", encoding="utf-8", buffering=1)


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css",
                      ".json": "application/json", ".svg": "image/svg+xml", ".html": "text/html"}

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def send_head(self):
        if any(part.startswith(".") for part in self.path.split("?")[0].split("/") if part):
            self.send_error(404)
            return None
        return super().send_head()


class Server(http.server.ThreadingHTTPServer):
    # the app loads ~40 ES modules and many icons at once: the default listen backlog (5) refuses connections on Windows
    request_queue_size = 128


if __name__ == "__main__":
    handler = functools.partial(Handler, directory=ROOT)
    with Server((HOST, PORT), handler) as httpd:
        print(f"Serving {ROOT} on http://{HOST}:{PORT}/", flush=True)
        httpd.serve_forever()
