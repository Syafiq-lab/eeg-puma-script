Watchfix v10 (hardened startup + diagnostics)
- Writes a bootstrap log even if the JSON config is missing or invalid.
- On success, migrates bootstrap lines into the main log and continues there.
- Saves watcher PID to watcher.pid for reliable Check/Stop without CIM access.
- Uses the full path to powershell.exe in launchers to avoid PATH/alias issues.
- Includes three launchers:
  * Run-Watcher-Hidden.bat  -> hidden background (no VBS)
  * Run-Watcher-Console.bat -> visible console (for debugging)
  * Run-Upload-Now.bat      -> one-shot run
- Heartbeat every 10s, logs Created/Changed/Renamed/Deleted/Error, poll fallback enabled.
