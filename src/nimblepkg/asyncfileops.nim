# Async file operations using chronos async processes
# Similar to Node.js - uses external commands for file I/O

import std/os
import chronos except Duration
import chronos/asyncproc

export chronos except Duration
export asyncproc

proc copyFileAsync*(source, dest: string): Future[void] {.async: (raises: [CatchableError, AsyncProcessError, AsyncProcessTimeoutError, CancelledError]).} =
  ## Async file copy using chronos async processes
  when defined(windows):
    # Windows: use xcopy for better handling
    let cmd = "xcopy /Y /Q " & quoteShell(source) & " " & quoteShell(dest) & "*"
  else:
    # Unix: use cp command with preserve permissions and recursive for dirs
    let cmd = "cp -f -p -r " & quoteShell(source) & " " & quoteShell(dest)

  let exitCode = await execCommand(cmd)
  if exitCode != 0:
    raise newException(IOError, "Failed to copy file from " & source & " to " & dest & " (exit code: " & $exitCode & ")")

proc copyDirAsync*(sourceDir, destDir: string): Future[void] {.async: (raises: [CatchableError, AsyncProcessError, AsyncProcessTimeoutError, CancelledError]).} =
  ## Async directory copy using chronos async processes - copies entire directory tree
  when defined(windows):
    # Windows: use robocopy for robust directory copying
    # /E = copy subdirs including empty, /NFL = no file list, /NDL = no dir list, /NJH = no job header, /NJS = no job summary, /NC = no class, /NS = no size, /NP = no progress
    let cmd = "robocopy " & quoteShell(sourceDir) & " " & quoteShell(destDir) & " /E /NFL /NDL /NJH /NJS /NC /NS /NP"
    let exitCode = await execCommand(cmd)
    # robocopy exit codes: 0-7 are success (0=no files, 1=files copied, 2=extra files, etc.)
    if exitCode > 7:
      raise newException(IOError, "Failed to copy directory from " & sourceDir & " to " & destDir & " (exit code: " & $exitCode & ")")
  else:
    # Unix: use cp -r to copy entire directory recursively
    let cmd = "cp -r -p " & quoteShell(sourceDir) & "/. " & quoteShell(destDir)
    let exitCode = await execCommand(cmd)
    if exitCode != 0:
      raise newException(IOError, "Failed to copy directory from " & sourceDir & " to " & destDir & " (exit code: " & $exitCode & ")")
