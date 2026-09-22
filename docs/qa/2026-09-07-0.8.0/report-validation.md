# Local HTML report validation

**PASS after two report-only fixes.** The initial headless run passed 106 of 107 assertions and exposed a saved-filter mismatch. Visual inspection found a separate narrow-header clipping issue. Both were fixed in `index.html`; all 26 focused follow-up assertions passed. This validates the report interface, not the app's release readiness.

## Frozen snapshot and isolation

The inventory agent froze `index.html` and `evidence.json` before the initial run. The snapshot represented product source `96b2025253ad71d01566713560ea7d101a13c53d`, with 33 recorded checks: 23 passed, six failed, and four unverified, across ten areas. It contained eight gallery images and 14 source-report links. The six failed entries include retained historical regression proofs and timeout observations; they are not a count of six newly discovered unresolved product defects.

Installed Python Playwright **1.58.0** launched the installed Chrome executable with `headless=True`; the browser reported `HeadlessChrome/152.0.0.0`. Each run used a fresh profile under the owned temporary browser evidence directory, loaded the page through `file://`, and set the browser context offline. No dependency install, local server, existing browser profile, foreground window, desktop input, product build, or app test suite was used. The root agent's pending macOS authorization prompt was not addressed by this work.

| Artifact | SHA-256 |
| --- | --- |
| Original frozen HTML | `adc689e7143db3323c62cf3a66201a5f92ac9b5823e2ee97a1ce1814e87f5b4d` |
| Fixed and retested HTML | `5091e50cd4af6f4c136519627a53aedb8f32929091582ec975a0335806283d3b` |
| Evidence JSON, unchanged | `3be0502f5617ff4c9af5c078179d06f888541c2c7ce9ab2f62b4bcb564b6fe42` |

Each browser run checked that its source files remained unchanged while it ran. The fixes also preserved the embedded evidence script byte-for-byte; evidence records and historical verdicts were not edited.

## Executed coverage

| Surface | Observed result |
| --- | --- |
| Offline startup and provenance | All 33 checks rendered; embedded data matched `evidence.json`; counts and candidate tooltip matched the data |
| Status filters | All, Passed, Failed, and Unverified returned the expected rows, counts, and pressed state |
| Area and search filters | All ten areas worked; ID search, case-insensitive search, surrounding whitespace, no-match guidance, and combined status/area/search worked |
| Details and methodology | Check details opened by click and closed with Enter; exact candidate provenance appeared; methodology disclosures toggled |
| Links and gallery | All rendered local links resolved to existing files; all eight images loaded, opened in the lightbox, had the expected original-image link, and closed via the button or Escape |
| Responsive layout | No page-level horizontal overflow at 1,440, 768, 390, or 320 pixels; the expanded detail also fit at 390 pixels |
| Evidence loading | Loading the real JSON worked offline; malformed JSON produced a visible error and preserved the previous rows |
| Save and reopen | Initially failed filter-state consistency; after the fix, the saved snapshot reopened with All selected and all 33 records, and all four filters remained functional |
| Runtime diagnostics | Initial run: zero JavaScript exceptions, console errors, or external page requests. Focused follow-up: zero JavaScript exceptions or external page requests |

Local-link validation checked resolved paths; it did not individually navigate every Markdown/JSON evidence file. The gallery's actual lightbox interactions were exercised. No video item was present, so video playback was not tested.

## Defects found and corrected

### Saved snapshot filter state — fixed

Reproduction: select **Failed**, save an HTML snapshot, then open the downloaded file offline. The cloned DOM retained `aria-pressed="true"` on Failed, while JavaScript initialized `activeStatus` to All and rendered every record. The result displayed Failed as selected alongside `Showing 33 of 33 checks`.

`renderHeader()` now derives each status button's pressed state from `activeStatus` when it renders the counts. Reopened snapshots consistently start at All; changing filters still works. Loading replacement evidence while Failed is selected retains a consistent Failed selection and its rows.

### Narrow header clipping — fixed

At both 390 and 320 pixels, the wrapped metadata was 85.234 pixels high inside a fixed 74-pixel header. Its top was **−6.109 pixels**, clipping the first line at the viewport edge. The mobile header now uses automatic height, a 74-pixel minimum, and vertical padding. After the fix, its metadata starts at **12 pixels** and ends at **97.234 pixels** inside the 110.234-pixel header. Desktop and tablet bounds also passed.

These were the only source edits in this validation task. Root retained commit ownership.

## Commands and durable evidence

From this report directory, the portable standalone runners use installed Playwright directly and create fresh profiles and outputs under a newly allocated temporary directory:

```sh
python3 evidence/report-browser/verify_report.py run-01
python3 evidence/report-browser/retest_fixes.py
```

The broad runner accepts a run-directory name; both runners allocate a fresh temporary parent and refuse to overwrite the run directory. These durable copies adapt only the original machine-specific input/output paths and output-location reporting; their syntax was checked during curation. The recorded browser runs used the original runners. Replays use the current report data and retain their own hashes.

- [Initial 107 assertions and diagnostics](evidence/report-browser/run-01/results.json), [raw log](evidence/report-browser/run-01.log)
- [Original narrow-header measurements](evidence/report-browser/layout-probe.json)
- [Exact two-change patch, hash and preservation receipt](evidence/report-browser/report-fixes.json)
- [Focused 26-assertion green result](evidence/report-browser/run-02/results.json), [raw log](evidence/report-browser/run-02.log)
- [Final desktop screenshot](evidence/report-browser/run-02/overview-1440.png), [390-pixel screenshot](evidence/report-browser/run-02/overview-390.png), [320-pixel screenshot](evidence/report-browser/run-02/overview-320.png)
- [Consistent saved snapshot](evidence/report-browser/run-02/saved-snapshot-consistent.png)
- [Expanded narrow detail](evidence/report-browser/run-01/mobile-detail.png), [desktop gallery](evidence/report-browser/run-01/desktop-gallery.png), [narrow gallery](evidence/report-browser/run-01/mobile-gallery.png)
- [Original clipped header](evidence/report-browser/run-01/mobile-overview.png), [original saved-filter mismatch](evidence/report-browser/run-01/saved-snapshot.png)
- [Curation manifest and file hashes](evidence/report-browser/manifest.json)
- [Browser cleanup receipt](evidence/report-browser/cleanup.json): zero remaining processes using the owned profiles

Screenshots were individually inspected after capture. The first automated overflow assertions only checked horizontal bounds; visual inspection caught the vertical clipping, which then received a measured regression check. Native file dialogs were avoided: Playwright supplied the JSON directly to the report's file input and captured its HTML download. Saved-report verification placed local evidence beside the downloaded file through owned symlinks, matching the report's instruction to keep its evidence folder alongside it.

Runner syntax and scoped `git diff --check` passed. Later changes to report data, scripts, or layout should retain their own snapshot hashes; this result does not silently transfer to a modified report.

## Evidence curation and privacy

Nine screenshots were individually inspected and copied unchanged into `evidence/report-browser/`. They show the report and approved synthetic/public app fixtures only. Browser profiles, downloaded DOM/symlinks, desktop captures, personal file panels, clipboard material, and private audio were excluded. JSON/log copies replace machine-specific absolute paths with stable placeholders; the manifest records source and curated hashes and each transformation. Counts, assertion verdicts, original HTML/evidence hashes, and the historical RED screenshots remain unchanged. The exact HTML patch is stored as a JSON string in its receipt.

This report preserves the 33-check frozen snapshot. Later dashboard data updates are separate evidence; these screenshots do not depict the latest release state. Curation does not imply a new browser run.

## Later data-only synchronization

After the root agent added newer release observations, the embedded `script#evidence-data` was synchronized with `evidence.json`: **36 checks, 26 passed, six failed, four unverified**. The synchronization preserved every byte outside that data script and parsed back to the same JSON. [The synchronization receipt](evidence/report-browser/later-data-sync.json) records the new hashes. No browser interaction was repeated for this data-only update; the 107/26-assertion runs and screenshots above retain their earlier snapshot provenance.

The separately requested hosted-review cleanup replaced workstation prefixes in nine audio evidence JSON files. [The path-redaction receipt](evidence/report-browser/review-path-redactions.json) records before/after hashes and substitution counts. The measured GUI track receipt remains unchanged.

## Completed report snapshot

The root reran the portable focused runner against the completed **43-check snapshot: 33 passed, six historical failures, four unverified**. All **26 assertions passed**. All four status filters, evidence reload, saved-snapshot state and content, header bounds, and horizontal overflow checks passed at 320, 390, 768 and 1,440 pixels. There were no JavaScript exceptions or external requests. Four captured report screenshots were individually inspected. This was a fresh offline headless browser, with no desktop input or product test rerun.

- [26-assertion result and source hashes](evidence/report-browser-final/results.json)
- [Desktop](evidence/report-browser-final/overview-1440.png), [390 pixels](evidence/report-browser-final/overview-390.png), [320 pixels](evidence/report-browser-final/overview-320.png), [saved snapshot](evidence/report-browser-final/saved-snapshot-consistent.png)
- [Unmodified artifact hashes](evidence/report-browser-final/manifest.json)

The exact HTML SHA-256 was `778271fcb86ce5e166deb365ef223806d4477b3ff6bfe6db002f80c057c4169c`; JSON was `012250048df0c89e9446dbb387cb559aa4adba91d4d91a72f00c5abb5d24f2b0`. Subsequent finalization changed only embedded evidence data: completed CI/merge status, a CI receipt link and four provenance descriptions. No script or CSS changed, and the 43 statuses remained unchanged. Embedded JSON equality and evidence links were checked again; the screenshots retain their pre-finalization wording.
