# Move prompt management out of the sidebar

Status: implemented on `feat/prompts-into-library`; PR review pending. Base:
`origin/main` at 54cdd2a2. Supersedes the sidebar placement in
[2026-09-08-prompt-management-navigation.md](2026-09-08-prompt-management-navigation.md).

## Why

The sidebar **Prompts** destination arrived with #961 as a single manager for
result prompts and Transforms. #990 moved Transforms out, leaving Transcript
prompts and Live Ask. Neither applies to dictation, and both are set up once and
then used where they run, so a top-level destination gave them more weight than
their use warrants. Settings → AI was considered and rejected as a hiding place;
the AI Formatter prompts stay there because they belong beside their switches.

## Product contract

- Remove the sidebar **Prompts** destination and its two-section workspace.
- Library's header gains a **Prompts** button that opens the existing transcript
  prompt manager as a sheet. Library is the home because it lists every
  transcript those prompts run on.
- Existing entry points stay: **Manage Prompts** in a transcript's generation
  popover and **After each meeting → Prompts** in Meetings.
- Live Ask questions stay in Meetings (**Meeting Prompts** section and the live
  Ask pane). No new Live Ask entry point.
- AI Formatter prompts stay in Settings → AI. Transforms is unchanged.

## Must not change

Prompt, version, collection, availability and auto-run storage; QuickPrompt
storage; CLI commands and categories; when prompts execute; the Transforms
screen. No migration. Sidebar selection is not persisted, so no stale-selection
fallback is needed.

## Implementation

1. Drop `SidebarItem.prompts`, restore `configItems` to Vocabulary, Feedback,
   Settings (Transforms inserted first when enabled), and delete
   `PromptsWorkspaceView`.
2. Remove the embed-only options that only the workspace used:
   `PromptLibraryView.isEmbedded`/`showsDismissButton` and
   `AskPromptsSheet.isEmbedded`. Both managers are sheets again everywhere.
3. Add an optional `onManagePrompts` action to `TranscriptionLibraryView`,
   rendered as a secondary **Prompts** button beside **Select Many**.
   `MainWindowView` owns the sheet and, on dismiss, clears editor state and
   reloads visible prompts for result generation. Meetings already refreshes
   its After-each-meeting card on appear.
4. Update `spec/04-ui-patterns.md`, `spec/12-processing-layer.md` and
   `integrations/README.md`.

## Verification

- Focused: `MainWindowStateTests`, `PromptManagementPresentationTests`,
  `PromptsViewModelTests`, `QuickPromptsViewModelTests`.
- One full `swift test` run before the PR.
- Native check of the dev app: sidebar has no Prompts; Library shows the Prompts
  button and the sheet opens, edits, and dismisses; Meetings entry points still
  open both managers.

Release notes line: "Prompts moved into Library (the Prompts button in the
header). Live Ask questions are still managed from Meetings."
