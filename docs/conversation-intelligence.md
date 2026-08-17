# Conversation Intelligence

Conversation Intelligence builds a private, local search index and an honest
activity summary from provider-native agent transcripts. Open it from
**Soyeht > Conversation Intelligence…**.

The MVP supports Codex, Claude Code, and OpenCode. Later adapters should use the
same `ConversationSourceAdapter` boundary instead of adding provider-specific
logic to the database or UI.

## Source and ownership model

The design has three deliberately asymmetric lanes:

1. Provider-native history is the content authority for sessions that are not
   bound to a canonical Soyeht conversation.
2. Canonical SAHP history is the future authority for bound Soyeht sessions and
   supplies exact relay metadata. The schema already records lane ownership,
   but this MVP imports native history only, so it cannot double-count a second
   canonical copy.
3. Hooks/reporters are wake-up signals only. They are never a content source.

Native authorities in this MVP:

- Codex rollouts under `~/.codex/sessions/`; `history.jsonl` is not ingested.
- Claude Code session JSONL under `~/.claude/projects/`.
- OpenCode's current SQLite store at
  `~/.local/share/opencode/opencode.db`, opened read-only with
  `PRAGMA query_only=ON`.

## Ingestion and live updates

Nothing is scanned until the user clicks **Scan last 90 days**. That scan is
bounded to the 250 newest sessions per provider. Large JSONL files are parsed
in 16 MiB batches, and cursor state is committed in the same transaction as
the derived turns.

After the first explicit scan, FSEvents watches only the three known provider
roots while the window is open. Events are coalesced, paths are neither logged
nor persisted, and a five-minute poll covers dropped events. **Backfill all
history** discovers the older corpus once and processes at most 100 sessions
per provider per batch with utility priority. It can be stopped without losing
cursor progress. If any subtree cannot be enumerated, the whole provider is
reported unavailable rather than presenting a partial index as complete.

Cursor identity combines a salted source key, provider source revision, byte
or time high-water mark, and a parser revision. A rewritten source replaces its
derived turns transactionally. Re-running an unchanged source is idempotent.

## Fail-closed authorship classification

`role=user` is never sufficient evidence that a person authored a prompt.
Each adapter emits schema-specific evidence and unknown forms remain excluded
from user metrics.

Claude's human-candidate rule is a conjunction:

- `promptSource` is `typed` or `queued`;
- `origin.kind` is `human`;
- `isMeta` is absent;
- the content has an allowed text shape; and
- the text is not a Soyeht relay envelope or handoff transport.

The envelope check is irreducible: Soyeht injects relays through the same input
path, so Claude can label an agent relay with `origin.kind=human`.
`suggestion_accepted` is human-initiated but not human-authored and is therefore
excluded. Meta, compacted, tool-result, sidechain, task-notification, and
unknown records have distinct non-human classifications.

The validation frame is intentionally explicit: automated fixtures cover the
declared shapes for three stores, and the optional real-machine smoke test
samples one newest session per store. This does not claim global classifier
accuracy. Every observed shape is compared with `ConversationSchemaManifest`;
an observed but undeclared shape surfaces as drift instead of silently becoming
human.

## Local search and Qwen embeddings

FTS5/BM25 search works without a model. Semantic search is a separate,
restartable queue and uses only:

- endpoint `http://127.0.0.1:11434`;
- exact model tag `qwen3-embedding:4b`;
- an Ollama catalog entry with a non-zero resident weight size; and
- 512-dimensional Matryoshka output.

The endpoint and model are not user-configurable. A weightless or cloud-only
catalog is rejected before any embedding request. This is an egress restriction
implemented by Soyeht, not an end-to-end guarantee about Ollama: Ollama is a
separate local daemon outside Soyeht's security boundary.

Passages and queries use separate formatting. Queries receive the Qwen
retrieval instruction; passages do not. Long turns are split into bounded,
paragraph-aware chunks, and search keeps the best cosine score for each turn.
The brute-force local scorer streams every stored vector, so older conversations
do not disappear behind a recency cutoff and the full vector corpus is not
materialized in memory at once.
Model digest and dimensionality are part of every vector key, so rankings never
mix embedding spaces after a model update. Old vectors remain until the new
digest is backfilled. **Update semantic index** drains the restartable queue in
bounded batches and can be stopped without losing completed vectors. The client
rechecks the resident digest around every embedding request and discards a batch
if the model changes mid-request.

Common credential forms are redacted before text crosses the local model
boundary. Ingestion and FTS continue when Ollama is unavailable.

## Privacy and deletion

Raw source and project paths exist only in adapter memory. Persisted source and
project keys are HMAC-SHA256 values using a random per-installation salt stored
with mode `0600`; the index directory is `0700` and database files are `0600`.
Project labels are neutral aliases. Source errors and UI messages never include
raw paths. No Full Disk Access request is made. A
missing, unreadable, or TCC-denied root is reported as unavailable instead of
being folded into a zero count.

**Clear index…** deletes all turns, FTS rows, vectors, relay edges, cursors, and
schema observations in one transaction. Native provider histories are not
modified. Per-source deletion uses the same provenance cascade. Dashboard
statistics are live SQL queries, not materialized aggregates, so removed data
cannot remain in a stale BI cache.

## Metrics and BI contract

The dashboard reports only directly observed facts:

- distinct native conversations;
- fail-closed candidate human prompts;
- visible agent replies;
- excluded/control records;
- stored semantic coverage; and
- Soyeht relay messages grouped by explicit sender and recipient.

It does not estimate attention, effort, time looking at a pane, or additive
session duration. Concurrent and resumed sessions make those claims invalid.
Every displayed count maps directly to a SQLite query over stored provenance.

## Verification

The standard package suite includes behavioral coverage for classification,
schema drift, partial JSONL tails, read-only OpenCode ingestion, idempotence,
bounded all-history backfill, salted paths, deletion cascades, relay graphs,
secret redaction, long-turn chunking, FTS fallback, hybrid retrieval, model
digest isolation, and refusal of cloud/weightless model catalogs.

The local integration smoke tests are opt-in because they read the developer's
installed provider stores and Ollama daemon. They write only to a temporary
database and never print transcript content:

```sh
SOYEHT_INTELLIGENCE_REAL_E2E=1 swift test --filter RealMachineSources
SOYEHT_INTELLIGENCE_REAL_E2E=1 swift test --filter ResidentQwenRanks
```

Future work: canonical SAHP ownership and live in-process events, adapters for
Droid/Kilo/Antigravity, explicit per-project aliases, a retained background
monitor independent of the dashboard window, and ranking evaluation over a
larger stratified truth set. Canonical per-agent metrics must not be enabled
until late reporter attribution is resolved in the canonical event path.
