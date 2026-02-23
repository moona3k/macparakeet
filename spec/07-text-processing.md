# 07 - Text Processing

> Status: **ACTIVE** - Authoritative, current

Text processing transforms raw STT output into polished text. MacParakeet offers a deterministic pipeline for fast, predictable results.

---

## Deterministic Pipeline (v0.2)

A 4-step pipeline that runs in sub-millisecond time. Pure function: same input always produces same output.

```
Raw STT Text → Filler Removal → Custom Words → Snippet Expansion → Whitespace Cleanup → Clean Text
```

### Step 1: Filler Removal

Removes verbal fillers in 3 tiers, ordered by aggressiveness:

**Multi-word fillers** (always removed):
- "you know", "I mean", "sort of", "kind of"

**Always-safe single-word fillers** (always removed):
- "um", "uh", "umm", "uhh"

**Sentence-start-only fillers** (removed only at the beginning of a sentence):
- "so", "well", "like", "right"

Implementation uses `NSRegularExpression` with word boundaries (`\b`) to avoid partial matches (e.g., "actually" the word is removed, but "factually" is not).

### Step 2: Custom Word Replacements

User-defined word corrections applied with case-insensitive matching and whole-word boundaries.

Two categories:

| Type | Purpose | Example |
|------|---------|---------|
| Vocabulary anchors | Enforce correct casing | "kubernetes" → "Kubernetes" |
| Corrections | Fix common STT errors | "aye pee eye" → "API" |

- Matching is **case-insensitive** with **whole-word boundaries**
- **Disabled** words are skipped (user can toggle without deleting)
- Applied in the order they appear in the database

### Step 3: Snippet Expansion

Trigger phrases are replaced with their full expansion text.

- **Triggers are natural language phrases**, not abbreviations — because Parakeet STT outputs natural speech, users will say "my signature" not "sig". Triggers must match what the STT actually produces.
- Snippets are **sorted by trigger length descending** (longest first) to prevent partial matches when one trigger is a prefix of another
- Matching is **case-insensitive** with **whole-phrase boundaries**
- Expanded snippet IDs are tracked so use counts can be updated after processing
- Example: `"my signature"` → `"Best regards, David"`

### Step 4: Whitespace Cleanup

Final normalization pass:

1. **Collapse multiple spaces** — `"hello   world"` → `"hello world"`
2. **Remove space before punctuation** — `"hello ."` → `"hello."`
3. **Trim** — strip leading/trailing whitespace
4. **Capitalize first letter** — ensure the first character is uppercase

---

## Processing Modes

| Mode | Processing | Engine | Latency |
|------|-----------|--------|---------|
| Raw | None | N/A | 0ms |
| Clean | Deterministic pipeline | TextProcessingPipeline | <1ms |

### Mode Details

**Raw**: No processing. The exact text output from Parakeet is used as-is. Useful for debugging or when the user wants full control.

**Clean** (default): The deterministic 4-step pipeline runs. Fast and predictable. Good for most dictation use cases.

---

## Database Tables

### custom_words

Stores user-defined vocabulary anchors and corrections.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID | Primary key |
| word | TEXT | The word/phrase to match (case-insensitive) |
| replacement | TEXT | The corrected word/phrase (nullable = vocabulary anchor) |
| source | TEXT | `.manual` (user-created) or `.learned` (auto-detected, future) |
| isEnabled | BOOLEAN | Whether this word is active |
| createdAt | DATETIME | When created |
| updatedAt | DATETIME | When last modified |

### text_snippets

Stores trigger-to-expansion mappings.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID | Primary key |
| trigger | TEXT | Natural language trigger phrase (e.g., "my address") |
| expansion | TEXT | The full expansion text |
| useCount | INTEGER | Number of times expanded |
| isEnabled | BOOLEAN | Whether this snippet is active |
| createdAt | DATETIME | When created |
| updatedAt | DATETIME | When last modified |

---

## CLI Commands

### Text Processing

```bash
# Run clean processing on text
macparakeet-cli flow process "um hello I mean kubernetes is great"
# → "Hello, Kubernetes is great."

# Process and copy to clipboard
macparakeet-cli flow process "text here" --copy

# Transcribe with processing
macparakeet-cli transcribe recording.wav --mode clean
macparakeet-cli transcribe recording.wav --mode raw
```

### Custom Words

```bash
# List all custom words
macparakeet-cli flow words list

# Add a vocabulary anchor
macparakeet-cli flow words add "kubernetes" "Kubernetes"

# Add a correction
macparakeet-cli flow words add "aye pee eye" "API"

# Delete a custom word
macparakeet-cli flow words delete <id>
```

### Text Snippets

```bash
# List all snippets
macparakeet-cli flow snippets list

# Add a snippet (trigger is a natural phrase, not an abbreviation)
macparakeet-cli flow snippets add "my signature" "Best regards, David"

# Delete a snippet
macparakeet-cli flow snippets delete <id>
```
