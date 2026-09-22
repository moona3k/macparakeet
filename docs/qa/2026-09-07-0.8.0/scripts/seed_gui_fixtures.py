#!/usr/bin/env python3
"""Insert synthetic GUI fixtures into an explicitly selected, stopped-app QA DB.

No migrations, provider configuration, source files, or existing rows are changed.
Requires the current app schema. See ../gui-fixtures.md for use and verification.
"""

import argparse
import json
import sqlite3
import uuid
from pathlib import Path


NAMESPACE = uuid.UUID("08008000-2026-4097-8080-000000000001")
CREATED_AT = "2026-09-07 12:00:00.000"  # GRDB's default UTC database Date encoding.

RICH_MARKDOWN = """# QA rich Markdown summary

## Release review

This is **bold fixture text**, *italic fixture text*, and `inline_code`.
These synthetic results were seeded locally; no model generated them.

| Check | Owner | Expected result |
| :--- | :--- | :--- |
| Timed rows | QA ALPHA Speaker | Copper lantern appears only in ALPHA |
| Replacement | QA BRAVO Speaker | Silver meadow appears only in BRAVO |
| Long scroll | QA LONG Speaker One | Final sentence 1000 remains reachable |

### Code sample

```json
{
  "fixture": "release-0.8.0",
  "localOnly": true,
  "expectedWords": 10000
}
```

> QA quotation: selection should remain readable across wrapped lines.

1. Inspect heading hierarchy and table alignment.
2. Select text and copy the complete result.
3. Export Markdown and compare it with the saved source.

- [x] Synthetic fixture prepared
- [ ] GUI rendering verified

[QA HTTPS link](https://example.com/qa-fixture)

[QA blocked file link](file:///tmp/macparakeet-qa-fixture-never-created.txt)

End marker: **QA MARKDOWN COMPLETE**.
"""


def fixture_id(name):
    return uuid.uuid5(NAMESPACE, name)


def json_text(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def transcript(name, marker, nouns, sentence_count, speaker_labels):
    words = []
    sentences = []
    for index in range(sentence_count):
        tokens = [marker, "fixture", "sentence", f"{index + 1:04d}", "keeps", *nouns,
                  "details", "clearly", "separate."]
        assert len(tokens) == 10
        speaker_index = (index // 50) % len(speaker_labels)
        speaker_id = f"qa-{marker.lower()}-{speaker_index + 1}"
        sentences.append(" ".join(tokens))
        for token in tokens:
            start = len(words) * 400
            words.append({"word": token, "startMs": start, "endMs": start + 400,
                          "confidence": 1.0, "speakerId": speaker_id})
    text = "\n\n".join(sentences)
    return {
        "id": fixture_id(name).bytes,
        "createdAt": CREATED_AT,
        "updatedAt": CREATED_AT,
        "fileName": f"{name}.wav",
        "titleOverride": name,
        "durationMs": len(words) * 400,
        "rawTranscript": text,
        "cleanTranscript": text,
        "wordTimestamps": json_text(words),
        "language": "en",
        "speakerCount": len(speaker_labels),
        "speakers": json_text([
            {"id": f"qa-{marker.lower()}-{index + 1}", "label": label}
            for index, label in enumerate(speaker_labels)
        ]),
        "status": "completed",
        "sourceType": "file",
        "isFavorite": 0,
        "isTranscriptEdited": 0,
        "recoveredFromCrash": 0,
        "derivedTitle": name,
        "derivedSnippet": sentences[0],
    }


def fixture_rows():
    alpha = transcript("QA 080 ALPHA", "ALPHA", ["copper", "lantern"], 24, ["QA ALPHA Speaker"])
    bravo = transcript("QA 080 BRAVO", "BRAVO", ["silver", "meadow"], 24, ["QA BRAVO Speaker"])
    long = transcript("QA 080 LONG 10000", "LONG", ["violet", "compass"], 1000,
                      ["QA LONG Speaker One", "QA LONG Speaker Two"])
    summary = {
        "id": fixture_id("QA 080 Markdown summary").bytes,
        "transcriptionId": alpha["id"],
        "promptName": "QA Markdown Preview",
        "promptContent": "Synthetic saved result for local rendering QA; do not generate.",
        "content": RICH_MARKDOWN,
        "createdAt": CREATED_AT,
        "updatedAt": CREATED_AT,
    }
    chat = {
        "id": fixture_id("QA 080 Markdown chat").bytes,
        "transcriptionId": alpha["id"],
        "title": "QA saved Markdown chat",
        "messages": json_text([
            {"role": "user", "content": "Show the saved QA Markdown example."},
            {"role": "assistant", "content": RICH_MARKDOWN.replace(
                "# QA rich Markdown summary", "# QA assistant Markdown reply", 1)},
        ]),
        "createdAt": CREATED_AT,
        "updatedAt": CREATED_AT,
    }
    return [("transcriptions", row) for row in (alpha, bravo, long)] + [
        ("summaries", summary), ("chat_conversations", chat)]


def seed(database, dry_run=False):
    # mode=rw prevents accidentally creating a DB at a mistyped path.
    connection = sqlite3.connect(database.as_uri() + ("?mode=ro" if dry_run else "?mode=rw"),
                                 uri=True, timeout=0)
    connection.execute("PRAGMA foreign_keys = ON")
    rows = fixture_rows()
    result = []
    try:
        for table, row in rows:
            columns = {column[1] for column in connection.execute(f'PRAGMA table_info("{table}")')}
            missing = row.keys() - columns
            if missing:
                raise ValueError(f"Unsupported {table} schema; missing: {', '.join(sorted(missing))}")
        connection.execute("BEGIN" if dry_run else "BEGIN IMMEDIATE")
        parent_ids = {}
        for table, original_row in rows:
            row = dict(original_row)
            identifier = uuid.UUID(bytes=row["id"])
            # Older GRDB records may use UUID text. Preserve them as well.
            existing = connection.execute(
                f'SELECT id FROM "{table}" WHERE id IN (?, ?, ?)',
                (identifier.bytes, str(identifier), str(identifier).upper()),
            ).fetchone()
            if table == "transcriptions":
                parent_ids[row["id"]] = existing[0] if existing else row["id"]
            else:
                row["transcriptionId"] = parent_ids[row["transcriptionId"]]
            if existing:
                action = "preserved"
            elif dry_run:
                action = "would_insert"
            else:
                columns = ", ".join(f'"{column}"' for column in row)
                placeholders = ", ".join("?" for _ in row)
                connection.execute(f'INSERT INTO "{table}" ({columns}) VALUES ({placeholders})', tuple(row.values()))
                action = "inserted"
            result.append({"table": table, "id": str(identifier), "action": action,
                           "name": row.get("titleOverride", row.get("promptName", row.get("title")))})
        if dry_run:
            connection.rollback()
        else:
            connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True, type=Path,
                        help="Existing disposable QA database; quit its app normally before insertion.")
    parser.add_argument("--dry-run", action="store_true", help="Read-only schema and existing-ID check.")
    arguments = parser.parse_args()
    try:
        results = seed(arguments.database.expanduser().resolve(), arguments.dry_run)
    except (OSError, sqlite3.Error, ValueError) as error:
        parser.exit(1, f"Fixture seeding failed: {error}\n")
    print(json.dumps({"database": str(arguments.database), "dryRun": arguments.dry_run,
                      "rows": results}, indent=2))


if __name__ == "__main__":
    main()
