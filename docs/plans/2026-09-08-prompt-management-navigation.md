# Clarify prompt management navigation

Status: implemented; PR verification pending. Base: 233b5f4d. This plan implements the user's approved separation without changing stored instructions or public CLI categories.

## Product contract

- Prompts is the management home for **Transcript prompts** and **Live Ask**, selected through two clearly named sections. Transcript prompts operate on completed transcriptions under the existing source and auto-run policies. Live Ask contains reusable questions used during meetings.
- Meetings remains the place to run Live Ask and choose automatic **After each meeting** outputs. Existing quick management entries reuse the corresponding manager.
- Transforms owns selected-text rewriting. Transcript managers never list, create, restore, or edit Transform rows. Remove the All prompts / Results / Transforms picker and redundant category badges. Use Transcript prompts or ordinary output language instead of Results as a management category.
- Existing Prompt/QuickPrompt IDs, stored categories, history, pinning, shortcuts, collections, availability policies, auto-run behavior, and CLI contracts remain intact. No migration or shared replacement data model.

## Implementation

1. Add a small Prompts workspace that defaults to Transcript prompts and selects Transcript prompts or Live Ask. Reuse PromptLibraryView and AskPromptsSheet rather than creating new CRUD implementations. Make the existing Ask manager embeddable without an inappropriate Done button or sheet-only sizing. Use the already configured QuickPromptsViewModel from the Meetings workspace.
2. Make PromptLibraryView transcript-only in every presentation. Scope active rows, Trash, creation defaults and editor category consistently. Preserve filtering/search and prompt settings. The transcript presentation remains usable in completed-transcript and Meetings management sheets.
3. Leave TransformsView, its editor, bindings, and view model unchanged, as explicitly requested by the user. Do not add an advanced manager or expand its feature set. Existing stored Transform versions/collections/settings remain intact and accessible through existing CLI commands; advanced controls formerly in the mixed Prompts view are not being moved into the Transform UI in this PR.
4. Keep Live Ask CRUD/pinning/grouping unchanged, and refresh the same repository-backed manager from either navigation entry. Collections apply to transcript/Transform instruction records; Live Ask retains its existing question grouping, with no collection controls incorrectly applied to it.
5. Update governing UI spec and relevant README/integration guidance to explain the navigation. Preserve technical category `result` and existing CLI commands; this is presentation, not a wire-format rename.

## Verification and review

- Focused tests for presentation scope, default creation category, and existing prompt/QuickPrompt/Transform state where affected. Verify active and deleted rows cannot cross scopes.
- Check Live Ask create/edit/pin access from Prompts and Meetings, shared-manager dismissal/refresh, and the existing Transforms screen remaining unchanged.
- No user database mutation for automated QA. Reuse existing build cache in the clean owning worktree; do not touch unrelated worktrees or user app state.
- Independent correctness/maintainability review, PR checks and review threads before merge. Full suite runs through CI; avoid redundant local full-suite runs.
- Open a real PR from feat/prompt-management-navigation; merge only its reviewed, passing head. User explicitly authorized implementation, PR and merge, but no release publication.

## Deliberate limits

No editor framework, database migration, new prompt type, collection migration, CLI renaming, or changes to when prompts execute. Transforms is explicitly outside this PR. Do not introduce another manager or consolidate its editor.

## Verification record

Independent source review found no remaining blocker after lifecycle and wording fixes. Focused local Release tests could not execute: the build exhausted local disk while compiling SwiftSyntax. CI owns the full test gate for this change; this failed local attempt is not a passing test result. No user database was changed for QA.
