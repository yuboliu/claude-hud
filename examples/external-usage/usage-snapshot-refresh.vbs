' claude-hud usage feeder launcher for Windows Task Scheduler.
'
' Runs usage-snapshot.mjs without flashing a console window every time the task
' fires: wscript.exe is a GUI-subsystem host (it never allocates a console), and
' Run(..., 0, ...) creates the child hidden (SW_HIDE). Scheduling the .mjs or a
' .cmd wrapper directly makes Task Scheduler flash a black cmd window instead.
'
' Install this file next to usage-snapshot.mjs in
' <CLAUDE_CONFIG_DIR>\plugins\claude-hud\ and register the task:
'
'   schtasks /Create /TN "claude-hud-usage-snapshot" /SC MINUTE /MO 3 ^
'     /TR "wscript.exe //B //Nologo ^"%USERPROFILE%\.claude\plugins\claude-hud\usage-snapshot-refresh.vbs^"" /F
'
' The feeder's stdout/stderr are appended to usage-snapshot.log next to it.
Option Explicit

Dim shell, fso, root, q, nodeExe, cmd

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Resolve from this file's own folder so the plugin directory can move freely.
root = fso.GetParentFolderName(WScript.ScriptFullName)
q = Chr(34)

nodeExe = shell.ExpandEnvironmentStrings("%ProgramFiles%") & "\nodejs\node.exe"
If Not fso.FileExists(nodeExe) Then
  nodeExe = "node.exe"
End If

cmd = "cmd.exe /d /c " & q & q & nodeExe & q & " " & q & root & "\usage-snapshot.mjs" & q _
  & " >> " & q & root & "\usage-snapshot.log" & q & " 2>&1" & q

' 0 = hidden window, False = do not wait for the feeder to finish.
shell.Run cmd, 0, False
