#!/usr/bin/env python3
"""Stage every S3 bucket into a temp dir, then run upstream ingestion over it."""

import os
import pathlib
import sys

import boto3
from botocore.client import Config

ENDPOINT = os.environ.get("S3_ENDPOINT", "http://s3:8333")
BUCKETS = [b for b in os.environ.get("S3_BUCKETS", "").split() if b]
STAGE_DIR = os.environ.get("S3_STAGE_DIR", "/tmp/s3")
SEP = os.environ.get("S3_KEY_SEP", "⁄")
SUFFIXES = {".txt", ".html", ".htm", ".md", ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".csv"}

s3 = boto3.client(
    "s3",
    endpoint_url=ENDPOINT,
    aws_access_key_id=os.environ.get("S3_ACCESS_KEY", "basaltrock"),
    aws_secret_access_key=os.environ.get("S3_SECRET_KEY", "basaltrock"),
    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
)

discovered = [b["Name"] for b in s3.list_buckets().get("Buckets", [])]
BUCKETS = BUCKETS + [b for b in discovered if b not in BUCKETS] if BUCKETS else discovered

stage = pathlib.Path(STAGE_DIR)
stage.mkdir(parents=True, exist_ok=True)

total = 0
for bucket in BUCKETS:
    try:
        pages = s3.get_paginator("list_objects_v2").paginate(Bucket=bucket)
        keys = [o["Key"] for page in pages for o in page.get("Contents", [])]
    except Exception as e:
        print(f"{bucket}: SKIPPED ({e})")
        continue

    kept = 0
    for key in keys:
        if key.endswith("/") or pathlib.PurePosixPath(key).suffix.lower() not in SUFFIXES:
            continue

        dest = stage / f"{bucket}{SEP}{key.replace('/', SEP)}"
        s3.download_file(bucket, key, str(dest))
        kept += 1
    print(f"{bucket}: {kept}/{len(keys)} objects staged")
    total += kept

if not total:
    print("No objects found in S3. Nothing to ingest.")
    sys.exit(0)

os.environ["DATA_DIR"] = STAGE_DIR
sys.argv = ["ingestion.py"]
exec(open("/app/ingestion.py").read(), {"__name__": "__main__", "__file__": "/app/ingestion.py"})