### Swift test results

- Cases in xUnit XML: **7929**; failures: **0**; errors: **0**.
- Skipped: not reported by this xUnit XML.
- Sum of 7929 case durations: **1571.89s** (parallel tests overlap; this is not wall time).

Slowest cases in xUnit XML:

| Case | Duration |
| --- | ---: |
| MacParakeetTests.TranscriptTimestampedLayoutSmokeTests.testLimitSizedTranscriptRendersNonLazilyAndSettles | 23.49s |
| MacParakeetTests.MeetingAecMeasurementTests.testNLMSDoubleTalkQuantifiesTheTradeoff | 22.37s |
| MacParakeetTests.MeetingAecMeasurementTests.testNLMSDoubleTalkSIRSweepReportsOverlapAccuracyAndEchoOnlyResidual | 22.37s |
| MacParakeetTests.MeetingAecMeasurementTests.testNLMSLeavesLocalVoiceUntouchedWhenRemoteIsSilent | 22.37s |
| MacParakeetTests.MeetingCleanedMicRendererTests.testAlignAndConditionAppliesRecordedStartOffset | 8.81s |
| MacParakeetTests.MeetingCleanedMicRendererTests.testAlignAndConditionCancelsEchoWhenAligned | 8.81s |
| MacParakeetTests.MeetingCleanedMicRendererTests.testAlignAndConditionOutputMatchesMicrophoneLength | 8.81s |
| MacParakeetTests.TranscriptDocumentLayoutTests.testLongMarkdownAndWideBlocksStayInsideCompactAndRegularPanes | 5.85s |
| MacParakeetTests.TranscriptChatViewModelTests.testUpdateTranscriptTextPreservesHistoryAndIsUsedOnNextSend | 5.85s |
| MacParakeetTests.LocalCLIExecutorTests.testTestConnectionConfigCapsTimeout | 5.34s |

Swift Testing (separate log summary; not included in the XML counts above): 30 tests passed after 0.004s.
