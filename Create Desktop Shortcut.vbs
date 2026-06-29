' Creates (or refreshes) a "W2 Monitor" shortcut on the Desktop that launches this app.
' Run this once after unzipping the W2Monitor folder anywhere on your PC.
Dim shell, fso, here, desktop, lnk
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
desktop = shell.SpecialFolders("Desktop")

Set lnk = shell.CreateShortcut(desktop & "\W2 Monitor.lnk")
lnk.TargetPath = here & "\Launch W2 Monitor.vbs"
lnk.WorkingDirectory = here
lnk.IconLocation = here & "\W2Monitor.ico, 0"
lnk.Description = "W2 Monitor - Elecraft W2 wattmeter monitor"
lnk.Save

MsgBox "Desktop shortcut 'W2 Monitor' created.", 64, "W2 Monitor"
