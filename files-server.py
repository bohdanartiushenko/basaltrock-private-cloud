#!/usr/bin/env python3
"""Serve source documents for the UI's download links.

The index stores a flat name, so a request is either "<bucket>/<key>" (served
from the object store) or a bare file name (looked up under the local roots).
"""

import os
import pathlib
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOTS = [pathlib.Path(p) for p in os.environ.get("FILE_ROOTS", "/srv/data").split(":")]
PORT = int(os.environ.get("FILE_PORT", "8080"))
ENDPOINT = os.environ.get("S3_ENDPOINT", "")
BUCKETS = set(b for b in os.environ.get("S3_BUCKETS", "").split() if b)

s3 = None
if ENDPOINT:
    import boto3
    from botocore.client import Config

    s3 = boto3.client(
        "s3",
        endpoint_url=ENDPOINT,
        aws_access_key_id=os.environ.get("S3_ACCESS_KEY", "basaltrock"),
        aws_secret_access_key=os.environ.get("S3_SECRET_KEY", "basaltrock"),
        config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    )


def _from_local(name: str):
    name = pathlib.PurePosixPath(name).name
    if not name or name.startswith("."):
        return None
    for root in ROOTS:
        if not root.is_dir():
            continue
        direct = root / name
        if direct.is_file():
            return direct.read_bytes(), direct.name
        for found in root.rglob(name):
            if found.is_file():
                return found.read_bytes(), found.name
    return None


def _from_s3(path: str):
    bucket, _, key = path.partition("/")
    if not key or (BUCKETS and bucket not in BUCKETS):
        return None
    try:
        obj = s3.get_object(Bucket=bucket, Key=key)
    except Exception:
        return None
    return obj["Body"].read(), pathlib.PurePosixPath(key).name


class Handler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        raw = urllib.parse.urlparse(self.path).path.lstrip("/")
        path = urllib.parse.unquote(raw)

        if path in ("", "health"):
            return self._text(200, b"ok")
        if ".." in path.split("/"):
            return self._text(404, b"not found")

        found = None
        if s3 is not None and "/" in path:
            found = _from_s3(path)
        if found is None:
            found = _from_local(path)
        if found is None:
            return self._text(404, b"not found")

        data, filename = found
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _text(self, code: int, body: bytes):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
