# Primary source documents — provenance

Hard, source-of-truth documents downloaded locally so the archive survives link
rot. Each entry: what it is, where it came from, and what it substantiates in
[`../../report.md`](../../report.md).

> **The PDFs are not committed to git** (they are ~33 MB of binaries, and every
> one is a freely re-downloadable public-domain government document or published
> patent). Run [`download-sources.sh`](./download-sources.sh) to rehydrate them
> into this directory. The OCR full text and this manifest are tracked.

## Patents (USPTO / Google Patents, primary)

| File | Document | Substantiates |
|---|---|---|
| `patent-US2766160.pdf` | US 2,766,160 — method of making laminated plastic tubing; inventor Itzhak Bentov | Early plastics/tubing invention; broad mechanical/process profile. |
| `patent-US3021573.pdf` | US 3,021,573 — process of making surface coats for masonry building units; inventor Itzhak Bentov, W. R. Grace assignee | Industrial coatings/materials work. |
| `patent-US3051678.pdf` | US 3,051,678 — scratch masking coating composition for masonry; inventor Itzhak Bentov, W. R. Grace assignee | Industrial coatings/materials work. |
| `patent-US3102540.pdf` | US 3,102,540 — means for administering medicine; inventor Itzhak E. Bentov | Medical-device work; not an EKG electrode or pacemaker lead. |
| `patent-US3119283.pdf` | US 3,119,283 — power transmission; inventor Itzhak Bentov, General Motors assignee | Automotive-adjacent power transmission; not a brake-shoe patent. |
| `patent-US3157178.pdf` | US 3,157,178 — dressing; inventor Itzhak Bentov, Oneida assignee | Wound dressing / medical-materials work. |
| `patent-US3165826.pdf` | US 3,165,826 — method of explosively forming fibers; inventor Itzhak E. Bentov | Materials/process invention. |
| `patent-US3167602.pdf` | US 3,167,602 — method of encapsulating liquid particles in thermoplastic shell; co-inventor Itzhak Bentov | Encapsulation/process invention. |
| `patent-US3313240.pdf` | US 3,313,240 — pump; inventor Itzhak E. Bentov | Metering/mixing pump invention. |
| `patent-US3394540.pdf` | US 3,394,540 — "means and method of converting fibers into yarn"; inventor Itzhak E. Bentov (11 pp) | His inventive range beyond medicine. |
| `patent-US3474791.pdf` | US 3,474,791 — multiple conductor electrode; inventor Itzhak E. Bentov, Brunswick assignee | Pacemaker/heart-stimulating electrode or lead claim. Does not prove an EKG-electrode claim. |
| `patent-US3491756.pdf` | US 3,491,756 — apparatus and method for preventing blood clotting; inventor Itzhak E. Bentov | Medical-device anti-clotting work; corrects a downstream table error that labels this as tube-making. |
| `patent-US3579858.pdf` | US 3,579,858 — anatomical model; inventor Itzhak E. Bentov, Medi-Tech assignee | Medi-Tech medical-device/training lineage. |
| `patent-US3605725A.pdf` | US 3,605,725 — controlled/steerable catheter tip; inventor **Itzhak E. Bentov**, assignee **Medi-Tech Inc.** (10 pp) | The steerable-catheter → Medi-Tech → Boston Scientific lineage. The single hardest fact in the whole story. |
| `patent-US4168709.pdf` | US 4,168,709 — dilator; inventor Itzhak E. Bentov | Late medical-device patent issued after Bentov's death from a lifetime application. |
| `patent-US4320762.pdf` | US 4,320,762 — dilator; inventor Itzhak E. Bentov | Continuation/divisional late medical-device patent naming Bentov after his death. |
| `patent-US5356368A.pdf` | US 5,356,368 — **Robert A. Monroe** / Interstate Industries; binaural-beat / frequency-following-response method (28 pp) | The Hemi-Sync mechanism the Gateway report is built around. Documents the *claim/method*, not its efficacy. |

Source: `https://patentimages.storage.googleapis.com/...` (Google Patents official PDF store). See `../patents-index.md` for the full normalized patent table, links, and claim-by-claim interpretation.

## The Gateway report (declassified US Army / CIA STARGATE, public domain)

| File | Document |
|---|---|
| `gateway-process-report.pdf` | "Analysis and Assessment of Gateway Process," Wayne M. McDonnell, 9 June 1983 — clean text-layer PDF |
| `gateway-process-CIA-original-scan.pdf` | The CIA reading-room image scan (29 pp) — the original as declassified |
| `gateway-process-recovered-page25.pdf` | The long-missing **page 25**, recovered (1 p) — the page absent from the CIA copy |
| `gateway-process-report-fulltext.txt` | OCR full text — grep here for the Bentov / 7 Hz / standing-wave passages |

Document number **CIA-RDP96-00788R001700210016-5**. Source: Internet Archive item
`1983-analysis-and-assessment-of-gateway-process` (the CIA reading-room direct-docs
path now 302-redirects and blocks direct fetch; this IA item mirrors the same
declassified document + the recovered page 25). Public domain (US Government work).
Substantiates §4 and the Bentov→McDonnell link.

## Flight 191 (NTSB, primary)

| File | Document |
|---|---|
| `NTSB-AAR7917-flight191.pdf` | NTSB Aircraft Accident Report AAR-79-17, American Airlines Flight 191, 25 May 1979 |

Source: `ntsb.gov/investigations/AccidentReports/Reports/AAR7917.pdf`. Public domain.
Substantiates §5 — the full accident cause chain (engine/pylon separation →
slat retraction → asymmetric stall). This is what makes the "assassination" reading
unsupported: a documented, non-selective maintenance/design failure.

## Deliberately NOT archived (copyright)

- ***Stalking the Wild Pendulum*** and Bentov's other books are **still in print**
  (Inner Traditions / Destiny Books). Redistributing a full scan would be a
  copyright violation. The report links the publisher pages and the Internet
  Archive borrow copy instead. If you want the text locally, borrow it through
  archive.org rather than mirroring it here.
