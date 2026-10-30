# Reading-view transcript edit

Issue [#1069](https://github.com/moona3k/macparakeet/issues/1069). The Text
view is where a finished transcript is read. Editing already existed on
Timed lines and could not delete a passage.

## What the user sees

- **Edit** on the Text header of a timed transcript.
- The same passages become fields. A passage can be rewritten or removed.
- **Done** saves. **Cancel** discards.
- One Undo restores that save.
- If a summary was generated from an older transcript revision, it says the
  transcript changed and offers **Update summary**.

Timed mode still owns speaker assignment, splits, and merges. Transcripts
without timing keep the existing whole-text editor.

## What stays underneath

`reviseText` is one correction command. Replacements keep the line's time
range. Omissions drop the passage from the effective transcript used by
search, export, shares, and later AI calls. Automatic words stay in the
recording. A summary that already ran is not recalled.
