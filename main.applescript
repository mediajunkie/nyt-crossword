-- NYT Crossword Chrome Helper
-- Scans all Chrome windows to find one logged into NYT.
-- Opens a new tab for the fetch and closes it when done — never hijacks existing tabs.
-- Launches Chrome with a specific profile to avoid the default/guest profile issue.

on run
	set configPath to "/tmp/nyt-crossword-config.txt"
	set resultPath to "/tmp/nyt-crossword-result.txt"

	-- Read parameters: line 1=printURL, line 2=todayDate, line 3=fileName, line 4=outputPath, line 5=dayOfWeek
	try
		set configContent to read POSIX file configPath
		set configLines to paragraphs of configContent
		set printURL to item 1 of configLines
		set todayDate to item 2 of configLines
		set fileName to item 3 of configLines
		set outputPath to item 4 of configLines
		set dayOfWeek to item 5 of configLines
	on error errMsg
		my writeResult(resultPath, "ERROR:CONFIG:" & errMsg)
		return
	end try

	try
		with timeout of 180 seconds
			-- Launch Chrome with the NYT-subscribed profile instead of bare "activate"
			-- This ensures Chrome opens with the right profile (xian@mediajunkie.com)
			-- even after Chrome updates that reset profile handling.
			do shell script "open -a 'Google Chrome' --args --profile-directory='Profile 1'"
			delay 3

			tell application "Google Chrome"
				if (count of windows) is 0 then
					make new window
					delay 2
				end if

				set windowCount to count of windows
				set dlResult to "ERROR:NOT_LOGGED_IN_ANY_WINDOW"

				repeat with w from 1 to windowCount
					set targetWindow to item w of windows

					-- Open a new tab in this window; don't navigate any existing tab
					set tabsBefore to count of tabs of targetWindow
					tell targetWindow
						make new tab
						set URL of last tab to "https://www.nytimes.com/crosswords"
						set active tab index to (tabsBefore + 1)
					end tell
					-- Bring this window to front so execute javascript works
					set index of targetWindow to 1
					delay 4

					tell active tab of front window
						execute javascript "
							window._nytResult = '';
							(async () => {
								try {
									let pdfUrl = '" & printURL & "';
									const dow = '" & dayOfWeek & "';
									try {
										const metaResp = await fetch('https://www.nytimes.com/svc/crosswords/v6/puzzle/daily/" & todayDate & ".json', {credentials: 'include'});
										if (metaResp.status === 401 || metaResp.status === 403) {
											window._nytResult = 'ERROR:HTTP_' + metaResp.status;
											return;
										}
										if (metaResp.ok) {
											const meta = await metaResp.json();
											const puzzleId = meta.id || meta.puzzle_id;
											if (puzzleId) {
												pdfUrl = 'https://www.nytimes.com/svc/crosswords/v2/puzzle/' + puzzleId + '.pdf';
												if (dow === '7') {
													pdfUrl += '?large_print=true';
												}
											}
										}
									} catch(e) {}
									const resp = await fetch(pdfUrl, {credentials: 'include'});
									if (resp.status !== 200) {
										window._nytResult = 'ERROR:HTTP_' + resp.status;
										return;
									}
									const blob = await resp.blob();
									if (!blob.type.includes('pdf')) {
										window._nytResult = 'ERROR:NOT_PDF:' + blob.type;
										return;
									}
									const reader = new FileReader();
									const b64 = await new Promise((resolve, reject) => {
										reader.onload = () => resolve(reader.result.split(',')[1]);
										reader.onerror = reject;
										reader.readAsDataURL(blob);
									});
									window._nytResult = 'OK:' + blob.size + ':' + pdfUrl;
									window._nytPdfBase64 = b64;
								} catch(e) {
									window._nytResult = 'ERROR:' + e.message;
								}
							})();
						"
						delay 6
						set dlResult to execute javascript "window._nytResult || 'PENDING'"
						if dlResult is "PENDING" then
							delay 4
							set dlResult to execute javascript "window._nytResult || 'PENDING'"
						end if

						if dlResult starts with "OK:" then
							set b64Data to execute javascript "window._nytPdfBase64 || ''"
							if b64Data is not "" then
								do shell script "echo " & quoted form of b64Data & " | base64 --decode > " & quoted form of outputPath
							else
								set dlResult to "ERROR:NO_BASE64_DATA"
							end if
						end if
					end tell

					-- Close the tab we opened
					close last tab of targetWindow

					-- Stop if we succeeded or hit a non-auth error
					if dlResult does not start with "ERROR:HTTP_401" and dlResult does not start with "ERROR:HTTP_403" then
						exit repeat
					end if
				end repeat

				my writeResult(resultPath, dlResult)
			end tell
		end timeout
	on error errMsg
		my writeResult(resultPath, "ERROR:APPLESCRIPT:" & errMsg)
	end try
end run

on writeResult(filePath, content)
	try
		set fileRef to open for access POSIX file filePath with write permission
		set eof fileRef to 0
		write content to fileRef
		close access fileRef
	on error
		try
			close access POSIX file filePath
		end try
	end try
end writeResult
