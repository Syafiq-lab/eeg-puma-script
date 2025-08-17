
Dim shell, scriptPath, psh
Set shell = CreateObject("WScript.Shell")
psh = "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
scriptPath = WScript.CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & "\uploader_watch.ps1"
shell.Run """" & psh & """" & " -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """ -Mode watch", 0, False
