#!/usr/bin/env python3
import argparse
import json
import socketserver
import time
from http.server import BaseHTTPRequestHandler


class ThreadingServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self._json(400, {"error": {"message": "invalid JSON"}})
            return

        if set(payload.keys()) != {"model", "messages", "stream"}:
            self._json(400, {"error": {"message": "unexpected request fields"}})
            return
        if payload.get("messages") != [
            {"role": "system", "content": "Translate the selected text."},
            {"role": "user", "content": "fixture selection only"},
        ]:
            self._json(400, {"error": {"message": "unexpected request content"}})
            return

        if self.path == "/nonstream":
            self._json(
                200,
                {"choices": [{"message": {"role": "assistant", "content": "一次性译文"}}]},
            )
        elif self.path == "/error/429":
            self._json(
                429,
                {
                    "error": {
                        "message": "请求过于频繁",
                        "fixture-private-detail": "must never cross XPC",
                    }
                },
            )
        elif self.path == "/stream":
            self._stream(
                [
                    b'data: {"choices":[{"delta":{"content":"\xe5\x88\x86\xe5\x9d\x97"},"finish_reason":null}]}\r\n\r\n',
                    b': heartbeat\n\n',
                    b'data: {"choices":[{"delta":{"content":"\xe8\xaf\x91\xe6\x96\x87"},"finish_reason":null}]}\n\n',
                    b'data: [DONE]\n\n',
                ],
                split=True,
            )
        elif self.path == "/slow-stream":
            self._start_stream()
            self._write(b'data: {"choices":[{"delta":{"content":"\xe9\x83\xa8\xe5\x88\x86"},"finish_reason":null}]}\n\n')
            time.sleep(5)
            self._write(b'data: [DONE]\n\n')
        elif self.path == "/early-eof":
            self._stream(
                [b'data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}\n\n']
            )
        elif self.path == "/heartbeats":
            self._start_stream()
            for _ in range(20):
                self._write(b': keep-alive\n\n')
                time.sleep(0.1)
        elif self.path == "/idle-heartbeats":
            self._start_stream()
            self._write(b'data: {"choices":[{"delta":{"content":"\xe5\xbc\x80\xe5\xa7\x8b"},"finish_reason":null}]}\n\n')
            for _ in range(20):
                self._write(b': keep-alive\n\n')
                time.sleep(0.1)
        elif self.path == "/role-heartbeats":
            self._start_stream()
            self._write(b'data: {"choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}\n\n')
            for _ in range(20):
                self._write(b': keep-alive\n\n')
                time.sleep(0.1)
        elif self.path == "/slow-nonstream":
            body = json.dumps(
                {"choices": [{"message": {"role": "assistant", "content": "too late"}}]}
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            time.sleep(2)
            self._write(body)
        elif self.path == "/oversized":
            self._start_stream()
            self._write(b"data: " + (b"a" * 1_048_577))
        else:
            self._json(404, {"error": {"message": "unknown fixture"}})

    def _json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self._write(body)

    def _start_stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

    def _stream(self, chunks, split=False):
        self._start_stream()
        for chunk in chunks:
            if split and len(chunk) > 4:
                cut = len(chunk) // 2
                self._write(chunk[:cut])
                time.sleep(0.01)
                self._write(chunk[cut:])
            else:
                self._write(chunk)
            time.sleep(0.01)

    def _write(self, data):
        try:
            self.wfile.write(data)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    with ThreadingServer(("127.0.0.1", args.port), Handler) as server:
        host, port = server.server_address
        print(f"http://{host}:{port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
