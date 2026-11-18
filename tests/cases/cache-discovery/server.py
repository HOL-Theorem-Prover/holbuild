"""Discovery transport fixture; cache responses are exercised by the SML test."""

import http.server
import pathlib
import sys


def main() -> None:
    root = pathlib.Path(sys.argv[1])

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            with (root / 'requests').open('a') as log:
                log.write(self.headers.get('Authorization', '') + '\n')
            if self.headers.get('Authorization') != 'Bearer fixture-token':
                self.send_error(401)
                return
            body = (root / 'body').read_bytes()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args: object) -> None:
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    (root / 'port').write_text(str(server.server_port))
    server.serve_forever()


if __name__ == '__main__':
    main()
