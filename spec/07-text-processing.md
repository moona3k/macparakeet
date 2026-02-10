# 07 - Text Processing

> Status: **ACTIVE** - Authoritative, current

Text processing transforms raw STT output into polished text. MacParakeet offers a deterministic pipeline for fast, predictable results, and optional LLM-powered modes for more sophisticated transformations.

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
- "um", "uh", "basically", "literally", "actually"

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
| Formal | Pipeline + LLM (professional tone) | Qwen3-4B | ~1-3s |
| Email | Pipeline + LLM (email format) | Qwen3-4B | ~1-3s |
| Code | Pipeline + LLM (preserve syntax) | Qwen3-4B | ~1-3s |

### Mode Details

**Raw**: No processing. The exact text output from Parakeet is used as-is. Useful for debugging or when the user wants full control.

**Clean** (default): The deterministic 4-step pipeline runs. Fast, predictable, no LLM dependency. Good for most dictation use cases.

**Formal**: The deterministic pipeline runs first, then the result is sent to Qwen3-4B with a prompt to rewrite in a professional tone. Suitable for business communication.

**Email**: Pipeline first, then LLM formats the text as an email with appropriate greeting, body, and sign-off. User's name and preferred sign-off can be configured.

**Code**: Pipeline first, then LLM preserves technical syntax, variable names, and code-like patterns while cleaning up natural language around them.

---

## Command Mode (v0.3)

A voice-controlled text transformation feature that works with any selected text in any app.

### Flow

```
User selects text in any app
    → Presses Fn+Ctrl (or configured shortcut)
    → MacParakeet activates, shows recording indicator
    → User speaks a command: "Translate to Spanish", "Make formal", "Fix grammar"
    → MacParakeet captures command via STT
    → Gets selected text via Accessibility API
    → Sends selected text + spoken command to Qwen3-4B
    → Replaces selected text with result via CGEvent (paste)
```

### Implementation

- **Get selected text**: Accessibility API (`AXUIElement`) to read the current selection from the focused app
- **Paste result**: `CGEvent`-based paste (Cmd+V simulation) to replace the selection
- Requires **Accessibility** permission (same permission as global hotkey)

### Example Commands

| Spoken Command | Effect |
|----------------|--------|
| "Translate to Spanish" | Translates selected text to Spanish |
| "Make formal" | Rewrites in professional tone |
| "Fix grammar" | Corrects grammar and spelling |
| "Summarize" | Condenses selected text |
| "Make shorter" | Reduces length while keeping meaning |
| "Add bullet points" | Reformats as a bulleted list |

### Constraints

- Selected text is limited to ~4000 tokens (Qwen3-4B context window management)
- If no text is selected, show a brief tooltip: "Select text first"
- Command recording uses the same mic pipeline as dictation

---

## LLM Integration

### Model

| Property | Value |
|----------|-------|
| Model | Qwen3-4B |
| HuggingFace ID | `mlx-community/Qwen3-4B-4bit` |
| Runtime | MLX-Swift |
| Memory | Loaded/unloaded on demand |

### Dual-Mode Operation

The same Qwen3-4B model is used with different settings depending on task complexity:

| Mode | Use Case | Temperature | Top-P |
|------|----------|-------------|-------|
| Non-thinking | Simple rewrites, formatting | 0.7 | 0.8 |
| Thinking | Complex commands, translation, reasoning | 0.6 | 0.95 |

### Memory Management

- The LLM is **not** loaded at app launch
- It loads on first LLM-mode dictation or command mode invocation
- It stays loaded for a configurable idle timeout (default: 5 minutes)
- After idle timeout, the model is unloaded to free memory
- Loading takes ~2-3 seconds; a loading indicator is shown in the UI

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
macparakeet flow process "um hello I mean kubernetes is great"
# → "Hello, Kubernetes is great."

# Process and copy to clipboard
macparakeet flow process "text here" --copy

# Transcribe with processing
macparakeet transcribe recording.wav --process
macparakeet transcribe recording.wav --process --copy
```

### Custom Words

```bash
# List all custom words
macparakeet flow words list

# Add a vocabulary anchor
macparakeet flow words add "kubernetes" "Kubernetes"

# Add a correction
macparakeet flow words add "aye pee eye" "API"

# Delete a custom word
macparakeet flow words delete <id>
```

### Text Snippets

```bash
# List all snippets
macparakeet flow snippets list

# Add a snippet (trigger is a natural phrase, not an abbreviation)
macparakeet flow snippets add "my signature" "Best regards, David"

# Delete a snippet
macparakeet flow snippets delete <id>
```
