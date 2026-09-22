# Evidence: Granola, Fireflies, Fathom (observed 2026-09-06)

## Granola speaker tags (https://docs.granola.ai/help-center/taking-notes/speaker-attribution)

- "When speaker tags aren't available or enabled, transcripts show Me and Them, corresponding to your microphone input and system audio."
- "Speaker tags show each participant's name above their parts of the conversation, giving you more detailed attribution than the default Me and Them labels."
- Google Meet: "Available on macOS and Windows through the Granola browser extension". Zoom: "Available on macOS through Settings > Preferences".
- Names come from meeting platform display names. Where tags are unavailable, "our AI usually does a good job of inferring speakers from contextual clues in the transcript."
- Corrections: "correct a name directly in your notes or ask Granola Chat to update it." Persistence across meetings: not documented.
- Limitations: cannot identify individuals sharing one device; overlapping speech not distinguished correctly; background audio may transcribe without attribution; applies only to active sessions, not retroactively.
- "Speaker tags do not record audio or video." They do not notify participants that Granola is in use.

## Granola transcription (https://docs.granola.ai/help-center/taking-notes/transcription)

- "Granola passes audio directly from your microphone and system audio to our transcription provider for the purpose of transcription."
- "It does not record or save audio or video at any point during the call, so there's no way to access audio from your meetings."
- Consequence: Granola has no retained audio to re-diarize, which is why its non-platform path is "Me/Them" plus LLM inference of names.

## Granola in-person / iPhone

- Granola blog (https://www.granola.ai/blog/ai-note-taker-in-person-meetings, search snippet 2026-09-06): the mobile app "can recognize different speakers during face-to-face meetings", "accuracy varies depending on the number of participants and how distinct the voices are." Internals not documented.

## Fireflies

- Edit speaker labels (https://guide.fireflies.ai/articles/4994477228-how-to-edit-speaker-labels-or-names-in-a-transcript): generic "Speaker 1, 2, etc." when metadata is unavailable; rename offers "Apply to current speaker (only that instance)" or "Apply to all 'Speaker X' (across the whole transcript)"; "Editing speaker labels does not change the actual audio"; regenerate notes after edits; only the meeting owner can edit. Propagation to future meetings: not documented.
- Privacy policy (https://fireflies.ai/privacy-policy, search snippet): service providers "do not use voice data to identify or authenticate individuals"; "Some service providers may temporarily process voice characteristics to distinguish speakers in transcripts"; biometric retention "within three years of an individual's last interaction" at most.
- Names come from calendar invites when available (search snippets from guide.fireflies.ai); live transcript uses generic labels and the post-call pass fills names (third-party summary, not verified on a Fireflies page).

## Fathom

- In-person (https://help.fathom.video/en/articles/5500225): "Fathom cannot distinguish between multiple speakers in the same physical room." "All audio will be attributed to the Fathom user's name in the transcript and summary."
- API transcript schema (https://developers.fathom.ai/api-reference/recordings/get-transcript): each item has `speaker.display_name` (required) and `speaker.matched_calendar_invitee_email` ("The email address of the calendar invitee matching this speaker. Null if no exact match found"), `text`, `timestamp` (HH:MM:SS).
