"""Serve a fake GitHub release tree for the installer tests.

Usage: python3 -I server.py <root> <port-file> <latest-version>

Files under <root> are served as they are, e.g.
/releases/download/v1.0.0-ext.1/codex-<target>.tar.gz. A request for
/releases/latest redirects to /releases/tag/v<latest-version>, as GitHub does.
The listening port is written to <port-file> once the server is ready.
"""

import functools
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class ReleaseHandler(SimpleHTTPRequestHandler):
    latest = ""

    def do_HEAD(self) -> None:
        if not self.release_page():
            super().do_HEAD()

    def do_GET(self) -> None:
        if not self.release_page():
            super().do_GET()

    def release_page(self) -> bool:
        """Answer /releases/latest (redirect) and /releases/tag/<tag> (empty page)."""
        if self.path == "/releases/latest":
            self.send_response(302)
            self.send_header("Location", f"/releases/tag/v{self.latest}")
        elif self.path.startswith("/releases/tag/"):
            self.send_response(200)
        else:
            return False
        self.send_header("Content-Length", "0")
        self.end_headers()
        return True

    def log_message(self, format: str, *args: object) -> None:
        pass


def main() -> None:
    root, port_file, latest = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
    ReleaseHandler.latest = latest
    handler = functools.partial(ReleaseHandler, directory=root)
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        port_file.write_text(str(server.server_address[1]))
        server.serve_forever()


if __name__ == "__main__":
    main()
