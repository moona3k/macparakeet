# Everyday use cases at the magic bar

**Date:** 2026-09-19. **Status:** local implementation + unit coverage. Live Google Flights search completion is still pending a rebuilt Dev app proof; do not treat this file as that proof.

The product contract: ordinary speech/typed intent drives the frontmost Mac/browser through observe → local route or Jev → execute → verify. Confirm only pay, delete, or send. Native Accessibility only. Jev picks among observed controls; local code owns URLs, form values, and app switching.

## Live evidence (2026-09-20)

Google Flights inbox turn in the Dev app **has not yet produced a results list**. Latest sessions locally open Flights, fill Zurich/London, commit city suggestions (including `Zürich` vs `Zurich`), type the date, and sometimes expose the September 20 calendar cell. The 2026-09-19 23:03 session stalled because Return ran while the origin overlay was still open (`duplicate_blocked`). The decision machine now classifies that overlay as `suggestionPicker` and **does not enable Return**. Competing city rows are a Jev Choice; a unique match stays local. Do not treat Flights as acceptance-complete.

YouTube / Maps / Wikipedia / web search / Gmail compose are unit-covered at the same local-router bar; they have not been live-qualified in this pass.

## What is local (no Jev) when the next step is unique

| Use case | Example | Local path | Confirm? |
|---|---|---|---|
| Open a running app | `open Notes`, `open Chrome` | Exact/fuzzy `activateApp` | No |
| Web goal from a non-browser | `Find flights…` while Cursor is front | Activate Chrome (or named browser) | No |
| Open an allowlisted site | flights, YouTube, Gmail, Maps, Wikipedia, Google Search | Press the `role=url` destination; Jev never sees URL targets | No |
| Google Flights search | `Find one-way flights from Zurich to London on September 20 2026.` | Fill origin/dest/date, unique autocomplete, Escape overlay, press Search flights | No |
| YouTube search | `Play the Apollo 11 documentary on YouTube` | Open YouTube, fill Search, Return or unique suggestion | No (playing a result can be Jev) |
| Web search | `Search the web for weather in London` | Open Google, fill the box | No |
| Maps | `Directions to the Golden Gate Bridge` | Open Maps, fill the box | No |
| Wikipedia | `Look up Alan Turing on Wikipedia` | Open Wikipedia, fill Search | No |
| Gmail compose | `Compose a new email in Gmail` | Open Gmail, press unique Compose | No. **Send** still confirms |
| Type into the focused field | `type hello` | `insertText` | No |
| Exact click | `click Done` | Unique label press | No unless the label is pay/delete/send |
| Scroll / undo / keys | `scroll down`, `undo`, `press escape` | Unique region or focused key target | Delete/Backspace on non-text confirms |
| Help | `what can I say` | Contextual list | No |

## What stays with Jev (or asks)

In-page next field when no local plan matches; choosing among several similarly named results; unfamiliar date pickers; any control whose consequence is payment, deletion, or send.

## What is later (researched, not this pass)

Spoken replies (on-device `AVSpeechSynthesizer`), Jev CLI evals, numbered on-screen picks, OCR, generated scripts, CDP/extensions, multi-step LLM planners. See [later](later.md) and [references](references.md).
