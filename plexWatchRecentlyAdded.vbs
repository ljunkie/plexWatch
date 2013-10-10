
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "C:\plexWatch\plexWatch.exe --recently_added=tv,movie", 0, True
Set WshShell = Nothing
