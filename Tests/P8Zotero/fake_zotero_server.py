#!/usr/bin/env python3
import argparse
import json
import socketserver
import time
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse


SERVER_ID = "lurume-zotero-fixture"


class ThreadingServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        path = parsed.path

        if self.headers.get("Zotero-API-Version") != "3":
            self._json(400, {"private": "missing API version"})
            return
        if path != "/api/" and self.headers.get("Zotero-Server-ID") != SERVER_ID:
            self._json(412, {"private": "server identity mismatch"})
            return

        if path == "/api/":
            self._json(200, {"ignored": "probe body is not forwarded"})
        elif path == "/api/users/0/groups":
            groups = [
                {"id": 21, "version": 3, "data": {"id": 21, "version": 3, "name": "研究组"}},
                {"id": 22, "version": 4, "data": {"id": 22, "version": 4, "name": "实验组"}},
            ]
            self._page(groups, query)
        elif path == "/api/users/0/collections":
            collections = [
                {"key": "ROOT", "version": 1, "data": {"name": "机器学习", "parentCollection": False}},
                {"key": "CHILD", "version": 2, "data": {"name": "翻译", "parentCollection": "ROOT"}},
                {"key": "OTHER", "version": 1, "data": {"name": "其他归属", "parentCollection": False}},
            ]
            self._page(collections, query)
        elif path == "/api/users/0/items":
            self._page(self._items(), query)
        elif path == "/api/groups/21/collections":
            self._page([], query)
        elif path == "/api/groups/21/items":
            self._page([], query)
        elif path == "/api/groups/403/collections":
            self._json(403, {"private": "communication disabled fixture detail"})
        elif path.endswith("/items/PDF1/file/view/url"):
            self._text("file:///fixture-does-not-exist/Zotero/storage/PDF1/paper.pdf\n")
        elif path.endswith("/items/MISSING/file/view/url"):
            self._json(404, {"private": "missing fixture path"})
        elif path.endswith("/items/CROSS/file/view/url"):
            port = self.server.server_address[1]
            self._redirect(f"http://localhost:{port}/cross-target")
        elif path.endswith("/items/WRONGID/file/view/url"):
            self._text("file:///fixture-does-not-exist/wrong-server.pdf", server_id="another-instance")
        elif path.endswith("/items/SLOW/file/view/url"):
            time.sleep(5)
            self._text("file:///fixture-does-not-exist/slow.pdf")
        elif path == "/cross-target":
            self._text("file:///fixture-does-not-exist/cross.pdf")
        else:
            self._json(404, {"private": "unknown fixture endpoint"})

    def _items(self):
        return [
            {
                "key": "PARENT1",
                "version": 5,
                "data": {
                    "itemType": "journalArticle",
                    "title": "A Fixture Paper",
                    "creators": [{"creatorType": "author", "firstName": "Ada", "lastName": "Lovelace"}],
                    "date": "2024-03-02",
                    "publicationTitle": "Fixture Journal",
                    "DOI": "10.1000/fixture",
                    "extra": "arXiv: 2401.01234",
                    "collections": ["CHILD", "OTHER"],
                    "tags": [{"tag": "fixture"}, {"tag": "local-only"}],
                    "relations": {"dc:relation": ["fixture"]},
                },
            },
            {
                "key": "PARENT2",
                "version": 1,
                "data": {
                    "itemType": "report",
                    "title": "No PDF Report",
                    "creators": [],
                    "collections": ["ROOT"],
                },
            },
            {
                "key": "PDF1",
                "version": 2,
                "data": {
                    "itemType": "attachment",
                    "title": "Accepted PDF",
                    "parentItem": "PARENT1",
                    "contentType": "application/pdf",
                    "filename": "paper.pdf",
                    "linkMode": "imported_file",
                },
            },
            {
                "key": "MISSING",
                "version": 1,
                "data": {
                    "itemType": "attachment",
                    "title": "Missing PDF",
                    "parentItem": "PARENT1",
                    "contentType": "application/pdf",
                    "filename": "missing.pdf",
                    "linkMode": "linked_file",
                },
            },
            {
                "key": "UNSUPPORTED",
                "version": 1,
                "data": {
                    "itemType": "attachment",
                    "title": "Remote Link",
                    "parentItem": "PARENT1",
                    "contentType": "application/pdf",
                    "filename": "remote.pdf",
                    "linkMode": "linked_url",
                },
            },
            {
                "key": "HTML1",
                "version": 1,
                "data": {
                    "itemType": "attachment",
                    "title": "Snapshot",
                    "parentItem": "PARENT1",
                    "contentType": "text/html",
                    "filename": "snapshot.html",
                    "linkMode": "imported_url",
                },
            },
            {
                "key": "NOTE1",
                "version": 1,
                "data": {
                    "itemType": "note",
                    "parentItem": "PARENT1",
                    "note": "fixture note content must not cross XPC",
                },
            },
        ]

    def _page(self, values, query):
        start = int(query.get("start", ["0"])[0])
        limit = int(query.get("limit", ["100"])[0])
        self._json(200, values[start : start + limit], {"Total-Results": str(len(values))})

    def _json(self, status, payload, headers=None):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Zotero-API-Version", "3")
        self.send_header("Zotero-Schema-Version", "42")
        self.send_header("Zotero-Server-ID", SERVER_ID)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self._write(body)

    def _text(self, value, server_id=SERVER_ID):
        body = value.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Zotero-API-Version", "3")
        self.send_header("Zotero-Schema-Version", "42")
        self.send_header("Zotero-Server-ID", server_id)
        self.end_headers()
        self._write(body)

    def _redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

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
