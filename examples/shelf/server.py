#!/usr/bin/env python3
"""Shelf's backend: an in-memory JSON API using only the standard library.

    python3 server.py [--port 8799] [--latency-ms 0] [--v2] [--seed default|empty|FILE.json]

Endpoints:
    GET    /books          -> 200 [Book]
    POST   /books          -> 201 Book   (422 when author is missing, 409 when the id exists)
    PUT    /books/<id>     -> 200 Book   (404 when missing)
    DELETE /books/<id>     -> 204        (404 when missing)
    POST   /events         -> 202 {}     (analytics; logged, not stored)
    GET    /stats          -> 200 {"total", "read", "unread", "byAuthor": [{"author", "count"}]}
    GET    /goal           -> 200 {"yearly", "read"}
    PUT    /goal           -> 200 {"yearly", "read"}   (422 unless yearly is an integer from 1 to 1000)
    GET    /catalog?q=     -> 200 [{"title", "author"}]  (catalog entries whose title or author contains q)

A Book is {"id": UUID, "title": str, "author": str, "isRead": bool, "addedAt": seconds since 1970}.
`--v2` is the planted contract change: responses say "writer" instead of "author" (requests accept
either), which the app doesn't decode.
"""

import argparse
import json
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

SEED_BOOKS = [
    {"id": "2A3F0C1E-8C55-4E0B-9C5A-0B5D7F3A1101", "title": "The Left Hand of Darkness",
     "author": "Ursula K. Le Guin", "isRead": False, "addedAt": 1767225600},
    {"id": "2A3F0C1E-8C55-4E0B-9C5A-0B5D7F3A1102", "title": "Piranesi",
     "author": "Susanna Clarke", "isRead": True, "addedAt": 1767312000},
    {"id": "2A3F0C1E-8C55-4E0B-9C5A-0B5D7F3A1103", "title": "Project Hail Mary",
     "author": "Andy Weir", "isRead": False, "addedAt": 1767398400},
]


CATALOG = [
    {"title": "Dune", "author": "Frank Herbert"},
    {"title": "Dune Messiah", "author": "Frank Herbert"},
    {"title": "Dubliners", "author": "James Joyce"},
    {"title": "The Dutch House", "author": "Ann Patchett"},
    {"title": "Emma", "author": "Jane Austen"},
    {"title": "Middlemarch", "author": "George Eliot"},
]


class Store:
    def __init__(self, books):
        self.lock = threading.Lock()
        self.books = {b["id"].upper(): dict(b) for b in books}
        self.order = [b["id"].upper() for b in books]
        self.events = []
        self.yearly_goal = 12

    def read_count(self):
        return sum(1 for b in self.books.values() if b.get("isRead"))

    def stats(self):
        authors = {}
        for key in self.order:
            author = self.books[key]["author"]
            authors[author] = authors.get(author, 0) + 1
        read = self.read_count()
        return {"total": len(self.order), "read": read, "unread": len(self.order) - read,
                "byAuthor": [{"author": a, "count": n} for a, n in sorted(authors.items(), key=lambda p: (-p[1], p[0]))]}

    def goal(self):
        return {"yearly": self.yearly_goal, "read": self.read_count()}


def make_handler(store, v2, latency_ms, quiet):
    def out(book):
        book = dict(book)
        if v2:
            book["writer"] = book.pop("author")
        return book

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            if not quiet:
                sys.stderr.write("server: " + fmt % args + "\n")

        def reply(self, status, body=None):
            data = b"" if body is None else json.dumps(body).encode()
            self.send_response(status)
            if body is not None:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def body(self):
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            try:
                return json.loads(raw or b"null")
            except ValueError:
                return None

        def route(self, method):
            if latency_ms:
                time.sleep(latency_ms / 1000)
            path = self.path.split("?", 1)[0].rstrip("/")
            parts = path.split("/")[1:]
            with store.lock:
                if parts == ["books"] and method == "GET":
                    return self.reply(200, [out(store.books[i]) for i in store.order])
                if parts == ["books"] and method == "POST":
                    book = self.body()
                    if not isinstance(book, dict) or not str(book.get("title") or "").strip():
                        return self.reply(422, {"error": "A title is required."})
                    book.setdefault("author", book.pop("writer", ""))
                    if not str(book.get("author") or "").strip():
                        return self.reply(422, {"error": "An author is required."})
                    key = str(book.get("id", "")).upper()
                    if not key:
                        return self.reply(422, {"error": "An id is required."})
                    if key in store.books:
                        return self.reply(409, {"error": "That book is already on the shelf."})
                    book = {"id": key, "title": book["title"], "author": book["author"],
                            "isRead": bool(book.get("isRead")), "addedAt": book.get("addedAt", time.time())}
                    store.books[key] = book
                    store.order.append(key)
                    return self.reply(201, out(book))
                if len(parts) == 2 and parts[0] == "books" and method in ("PUT", "DELETE"):
                    key = parts[1].upper()
                    if key not in store.books:
                        return self.reply(404, {"error": "No such book."})
                    if method == "DELETE":
                        del store.books[key]
                        store.order.remove(key)
                        return self.reply(204)
                    update = self.body() or {}
                    update.setdefault("author", update.pop("writer", store.books[key]["author"]))
                    for field in ("title", "author", "isRead"):
                        if field in update:
                            store.books[key][field] = update[field]
                    return self.reply(200, out(store.books[key]))
                if parts == ["stats"] and method == "GET":
                    return self.reply(200, store.stats())
                if parts == ["goal"] and method == "GET":
                    return self.reply(200, store.goal())
                if parts == ["goal"] and method == "PUT":
                    update = self.body()
                    yearly = update.get("yearly") if isinstance(update, dict) else None
                    if not isinstance(yearly, int) or isinstance(yearly, bool) or not 1 <= yearly <= 1000:
                        return self.reply(422, {"error": "A goal is 1 to 1000 books."})
                    store.yearly_goal = yearly
                    return self.reply(200, store.goal())
                if parts == ["catalog"] and method == "GET":
                    query = parse_qs(urlsplit(self.path).query).get("q", [""])[0].casefold()
                    return self.reply(200, [e for e in CATALOG if query in e["title"].casefold()
                                            or query in e["author"].casefold()])
                if parts == ["events"] and method == "POST":
                    store.events.append(self.body())
                    return self.reply(202, {})
            return self.reply(404, {"error": f"No route for {method} {path}."})

        def do_GET(self):
            self.route("GET")

        def do_POST(self):
            self.route("POST")

        def do_PUT(self):
            self.route("PUT")

        def do_DELETE(self):
            self.route("DELETE")

    return Handler


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        # HTTPServer.server_bind calls socket.getfqdn, which can stall for seconds on macOS.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8799)
    parser.add_argument("--latency-ms", type=int, default=0, help="delay every response")
    parser.add_argument("--v2", action="store_true", help="rename author to writer in responses")
    parser.add_argument("--seed", default="default", help="default, empty, or a JSON file of books")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    if args.seed == "default":
        books = SEED_BOOKS
    elif args.seed == "empty":
        books = []
    else:
        with open(args.seed) as f:
            books = json.load(f)
    server = Server(("127.0.0.1", args.port), make_handler(Store(books), args.v2, args.latency_ms, args.quiet))
    print(f"shelf server listening on http://127.0.0.1:{args.port}"
          f"{' (v2: author is now writer)' if args.v2 else ''}", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
