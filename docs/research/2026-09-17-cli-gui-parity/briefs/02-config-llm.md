# Brief 02 — Shared preferences and LLM config robustness

One concern: determine whether CLI `config` and LLM-backed CLI commands actually share the GUI's preference/provider state, especially for Homebrew vs app-bundled CLI.

## Settled

- `AppPaths.appDefaults(bundleIdentifier:)` is the intended cross-process preference resolver (`Sources/MacParakeetCore/Services/AppPaths.swift`).
- `macparakeet-cli config` uses `macParakeetAppDefaults()`.
- Do not propose storing API keys as CLI flags in shell history.

## Hypotheses to confirm or kill with evidence

1. `LLMConfigStore` and `LocalCLIConfigStore` default to `UserDefaults.standard`, so Homebrew CLI `cards generate` / default `LLMService()` may miss GUI-saved provider metadata.
2. `SpeechEnginePreference.current(defaults: .standard)` vs CLI passing `macParakeetAppDefaults()` — find any CLI path that forgets to pass the suite.
3. `UserDefaultsAppRuntimePreferences` default `.standard` — GUI OK, Homebrew CLI maybe not for any CLI caller that constructs it without the suite.
4. `config` key coverage vs `AppRuntimePreferences` / `AppPreferences` / `CalendarAutoStartPreferences` keys. Which missing keys are automation-relevant vs GUI-only chrome?

## Fences

- Read-only. Write only: `docs/research/2026-09-17-cli-gui-parity/02-config-llm.md`
- Do not implement. Do not touch other agent files.

## Done

File with: confirmed bugs vs disproven hypotheses; exact call sites; recommended smallest fix; config-key table classified `expose` / `gui-only` / `already-exposed`.
