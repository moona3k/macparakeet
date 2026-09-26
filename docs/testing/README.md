# End-to-end qualification

Use the smallest journey that crosses the boundary being changed. Keep deterministic
race/error tests alongside these journeys; GUI or model runs cannot reliably force
all cancellation and persistence orderings.

The CLI round trip merged in [#1164](https://github.com/moona3k/macparakeet/pull/1164).
Additional guides and runners merged in
[#1171](https://github.com/moona3k/macparakeet/pull/1171) (model),
[#1172](https://github.com/moona3k/macparakeet/pull/1172) (native Library), and
[#1173](https://github.com/moona3k/macparakeet/pull/1173) (process recovery).
Their PR checks passed, including actual dedicated synthetic process recovery.
The [combined-main CI run](https://github.com/moona3k/macparakeet/actions/runs/36247644540)
at `529e23ad` also passed, including explicit process-recovery execution.
No actual native GUI, real-model inference, or physical microphone/device
qualification has been demonstrated by the recorded checks.

The later [CI follow-up #1175](https://github.com/moona3k/macparakeet/pull/1175)
also runs the older raw-container crash test explicitly and requires real signal
termination. Its [cache qualification](../research/2026-09-26-ci-optimization.md#correctness-evidence)
proves changed app source/resources reach a rebuilt package after restoring build
state; it does not launch the app or extend the physical/model qualification boundary.


| Boundary | Entry point | Execution and limits |
| --- | --- | --- |
| CLI → database → export | [`MeetingCLIProcessTests`](../../Tests/CLITests/MeetingCLIProcessTests.swift), plus [`cli-persistence-smoke.py`](../../scripts/ci/cli-persistence-smoke.py) | Ordinary CI; real executable invocations and owned databases/artifacts, synthetic content, no speech model |
| Capture writer → process death → recovery | [Meeting process recovery](meeting-process-recovery.md) | Explicit filtered CI step; real writer, SIGKILL, fresh-process recovery and artifacts, synthetic capture and stub recognition |
| Native Library → durable notes → relaunch/export | [Native Library journey](native-library-e2e.md) | Opt-in logged-in disposable account with Accessibility; actual GUI runtime qualification remains separate from compiling the runner |
| File → real model → fresh CLI readback/export | [Model qualification](model-qualification.md) | Opt-in Apple Silicon account, prebuilt CLI and accepted preprovisioned assets; child networking denied |
| Microphone, delivery and device routes | [Physical journeys](model-qualification.md#physical-journeys-still-require-devices-and-a-person) | Manual signed-app qualification with actual devices, permissions and recorded evidence |

A missing prerequisite is not a pass. CI helper checks prove driver behavior,
not successful native UI automation or real speech inference. Consult each guide
for commands, evidence retention and isolation boundaries. A state-directory or
database override alone does not isolate shared preferences or Keychain.

The [test-value audit](../research/2026-09-25-test-value-audit.md#expanded-end-to-end-qualification)
records implementation and observed results. The
[CI report](../research/2026-09-25-ci-cost-and-test-strategy.md#implemented-result)
separates measured timing changes from unimplemented optimization experiments.
