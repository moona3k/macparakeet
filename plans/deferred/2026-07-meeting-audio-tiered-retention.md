# Meeting Audio Tiered Retention (DEFERRED 2026-07-03)

Decision: under storage pressure, delete derived audio before source audio:
microphone-cleaned.m4a -> meeting.m4a (mixed; regenerable from sources) ->
microphone.m4a + system.m4a LAST (the re-derivation root). Today's bulk
cleanup removes all managed audio at once. Deliberately deferred: do not build
until users raise storage complaints; "Remove Audio Only" is simple and
honest. Revisit trigger: storage-related issues/feedback.
