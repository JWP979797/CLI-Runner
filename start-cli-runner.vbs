Set WshShell = CreateObject("WScript.Shell")
<<<<<<< HEAD

WshShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""C:\Users\smartport\Desktop\cli-runner\cli-runner.ps1""", 0, False
=======
Set FSO = CreateObject("Scripting.FileSystemObject")

scriptDir = FSO.GetParentFolderName(WScript.ScriptFullName)
ps1Path = scriptDir & "\cli-runner.ps1"

<<<<<<< HEAD
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1Path & """", 0, False
>>>>>>> 2eede40 (Restore CLI Runner files)
=======
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps1Path & """", 1, False
>>>>>>> d8564bf (a)
