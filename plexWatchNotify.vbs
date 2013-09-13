
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "C:\plexWatch\plexWatch.exe --notify", 0, True

Set WshShell = Nothing
