# basaltrock-private-cloud

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Docker 4.40+](https://img.shields.io/badge/Docker-4.40%2B%20(Model%20Runner)-blue?logo=docker)](https://www.docker.com/)
[![Make](https://img.shields.io/badge/Make-build%20tool-orange?logo=gnu)](Makefile)
<a href="https://github.com/seaweedfs/seaweedfs"><img src="docs/seaweedfs.svg" alt="" height="20" align="top"></a>
[![SeaweedFS](https://img.shields.io/badge/SeaweedFS-object%20store-blue)](https://github.com/seaweedfs/seaweedfs)

Private-cloud RAG stack over [basaltrock](https://github.com/bohdanartiushenko/basaltrock).
Put documents in one folder and ask them in plain language. Everything runs on your
machine; documents are never sent anywhere.

Run standalone, or include the Makefile from a locale repo (see
[basaltrock-ua](https://github.com/bohdanartiushenko/basaltrock-ua) for Ukrainian).

## Usage

```bash
make up DATA_FOLDER=xyz   # index xyz and start on :80
make ingest               # re-index after changing documents
make down                 # stop, keeping the index
make help                 # all targets
```

Answers cite their sources; each citation is a download link to the original
document.

Folder and file names must be ASCII. Document *contents* may be in any
language.

## Several data sources

One `DATA_FOLDER` is one data source, named after the folder. Add more by
copying a folder in, then re-indexing:

```bash
make store sync ./archive store://archive
make ingest
```

`make ingest` indexes every data source it finds, so a new one needs no
configuration. `make store` passes its arguments to
[rclone](https://rclone.org/commands/), so `ls`, `copy`, `delete` and friends
work too, in either direction:

```bash
make store ls store://archive          # list one source
make store sync store://archive ./out  # copy a source back out
```

`make ingest` is also spelled `make basaltrock-agent start-ingestion-job`, and
`make ls` as `make basaltrock-agent list-knowledge-base-documents`, mirroring
`aws bedrock-agent`.

## Architecture

![Architecture](docs/private-cloud.png)

Source: [`docs/private-cloud.puml`](docs/private-cloud.puml).

Documents are held in a single-node
[SeaweedFS](https://github.com/seaweedfs/seaweedfs) store (Apache-2.0), which
plays the part of Bedrock's S3 data source: one bucket per data source, and the
same path-style S3 API. `make` drives it, so the targets above are all that is
needed day to day.

## Reuse from a locale repo

```make
PROJECT_NAME       = basaltrock-xx
PRIVATE_CLOUD_DIR  = .private-cloud
SYSTEM_PROMPT_FILE = system-prompt.xx.txt
INDEX_HTML         = index.xx.html
DOC_ANSI_CODEPAGE  = cp1251

include $(PRIVATE_CLOUD_DIR)/Makefile
```

`PROJECT_NAME` namespaces the compose project and its volumes, so several
locales coexist. Override any of `DATA_FOLDER`, `MODEL_RUNNER_LLM_CHAT`,
`MODEL_RUNNER_LLM_EMBEDDING`, `MODEL_CONTEXT_SIZE`.

## System prompt

`system-prompt.txt` supports three placeholders, substituted in the browser:

| Placeholder | Present | Absent |
|---|---|---|
| `{context}` | retrieved chunks | no context — required in practice |
| `{history}` | transcript inlined | sent as `messages` turns |
| `{question}` | question inlined | sent as final user message |

Place `{question}` only together with `{history}`. With `{question}` inlined but
history left in `messages`, the last message is the assistant's and the model
continues that turn instead of answering.

This template does not render via `/retrieveAndGenerate`: that endpoint calls
`tmpl.format(context=...)`, which raises `KeyError` on `{history}` and is
silently swallowed upstream, leaving the placeholders literal.

## Retrieval

The UI issues two calls per question:

1. `POST /knowledgebases/{id}/retrieve` — question only
2. `POST /model/{id}/converse` — retrieved context plus history

History never reaches the embedding step. Sending both in one
`/retrieveAndGenerate` call lets a long transcript dominate the query vector, so
follow-up questions retrieve the previous topic's documents instead of their own.

## Supported files

`.txt`, `.md`, `.pdf`, `.doc`, `.docx`, `.xls`, `.xlsx`, `.csv`, `.html`

For garbled text from legacy `.doc`, set `DOC_ANSI_CODEPAGE` to the right
codepage (`cp1251` for Cyrillic, `cp1252` for Western European).

## Data

`make down` keeps the OpenSearch index in the `opensearch_data` volume.
`make prune` deletes it.

## License

MIT. Built on [basaltrock](https://github.com/bohdanartiushenko/basaltrock).