#!/bin/sh
# A stand-in for SumatraPDF, for readq's tests.
# Logs its arguments to $FAKE_SUMATRA_LOG, waits $FAKE_SUMATRA_SLEEP
# seconds (the time you read), then, if $FAKE_SUMATRA_PAGE is set,
# writes $FAKE_SUMATRA_SETTINGS the way SumatraPDF does when you close a
# document: the last argument is the file, shown at that page.
echo "$@" >> "$FAKE_SUMATRA_LOG"
for last; do :; done
sleep "${FAKE_SUMATRA_SLEEP:-0}"
if [ -n "$FAKE_SUMATRA_PAGE" ]; then
  cat > "$FAKE_SUMATRA_SETTINGS" <<END
Theme = Light
RememberOpenedFiles = true
FileStates [
	[
		FilePath = $last
		Favorites [
			[
				Name = Fav
				PageNo = 999
			]
		]
		OpenCount = 2
		PageNo = $FAKE_SUMATRA_PAGE
		Zoom = fit width
	]
]
SessionData [
	[
		TabStates [
			[
				FilePath = $last
				PageNo = 555
			]
		]
	]
]
END
fi
