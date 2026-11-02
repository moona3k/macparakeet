### Swift test results

Tested commit: `d66cfae0f868c95be5fa37ec31e6f64c56cf362e`. This run predates integration of PR #1309 and the title fixes in `0146098b013e`; later focused results are attributed separately in the [release audit](../README.md).

- Cases in xUnit XML: **8519**; failures: **0**; errors: **0**.
- Skipped: not reported by this xUnit XML.
- Sum of 8519 case durations: **1772.65s** (parallel tests overlap; this is not wall time).

Slowest cases in xUnit XML:

| Case | Duration |
| --- | ---: |
| MacParakeetTests.MeetingActivityPromptPolicyTests.testVisiblePromptSurvivesMissingEvidenceUntilGraceExpires | 8.68s |
| MacParakeetTests.MeetingAecMeasurementTests.testDoubleTalkScenarioKeepsEchoPathConsistentWhenPathIsNonlinear | 8.68s |
| MacParakeetTests.MeetingAecMeasurementTests.testNLMSDoubleTalkQuantifiesTheTradeoff | 8.68s |
| MacParakeetTests.MeetingAecMeasurementTests.testNLMSDoubleTalkSIRSweepReportsOverlapAccuracyAndEchoOnlyResidual | 8.68s |
| MacParakeetTests.LocalCLIExecutorTests.testTimeoutWhileChildIsNotDrainingStdin | 7.03s |
| MacParakeetTests.LocalCLIExecutorTests.testTimeout | 7.03s |
| MacParakeetTests.CrashReporterSignalProbeTests.testEveryInstalledSignalExitsViaItsOwnDefaultDisposition | 3.98s |
| MacParakeetTests.CrashReportStoreTests.testUnreadableReportIsRetainedAndRetriedAfterPermissionsRecover | 3.98s |
| MacParakeetTests.CrashReporterSignalProbeTests.testSubprocessAbruptBacktraceExitPreservesAlreadyWrittenMinimum | 3.98s |
| MacParakeetTests.CrashReporterSignalProbeTests.testSubprocessAbortWritesMinimalSignalReportAndExitsViaDefaultDisposition | 3.98s |

Swift Testing (separate log summary; not included in the XML counts above): 30 tests passed after 0.005s.
