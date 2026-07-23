"""HTTP server that serves repodata normally but stalls on RPM downloads.

Used to test --max-workers by counting established TCP connections
while RPM downloads are stalled.

Usage: python3 stall_server.py [directory] [port]
"""

import http.server
import os
import sys
import time


class StallOnRpmHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/repodata/"):
            super().do_GET()
        else:
            self.send_response(200)
            self.send_header("Content-Length", "999999999")
            self.end_headers()
            while True:
                time.sleep(60)

    def log_message(self, format, *args):
        sys.stderr.write("%s - - %s\n" % (self.client_address[0], format % args))
        sys.stderr.flush()


if __name__ == "__main__":
    directory = sys.argv[1] if len(sys.argv) > 1 else "."
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
    os.chdir(directory)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), StallOnRpmHandler)
    print(f"Serving {directory} on 127.0.0.1:{port} (stalling RPM downloads)")
    sys.stdout.flush()
    srv.serve_forever()
