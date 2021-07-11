#
#
#       Asynchronous tools for Nim Language
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

## This module implements an advanced facility for executing OS processes
## and process communication in asynchronous way.
##
## Most code for this module is borrowed from original ``osproc.nim`` by
## Andreas Rumpf, with some extensions, improvements and fixes.
##
## API is near compatible with stdlib's ``osproc.nim``.

import strutils, os, strtabs
import asyncdispatch, asyncpipe

when defined(windows):
  import winlean
else:
  const STILL_ACTIVE = 259
  import posix

when defined(linux):
  import linux

type
  ProcessOption* = enum  ## options that can be passed `startProcess`
    poEchoCmd,            ## echo the command before execution
    poUsePath,            ## Asks system to search for executable using PATH
                          ## environment variable.
                          ## On Windows, this is the default.
    poEvalCommand,        ## Pass `command` directly to the shell, without
                          ## quoting.
                          ## Use it only if `command` comes from trusted source.
    poStdErrToStdOut,     ## merge stdout and stderr to the stdout stream
    poParentStreams,      ## use the parent's streams
    poInteractive,        ## optimize the buffer handling for responsiveness for
                          ## UI applications. Currently this only affects
                          ## Windows: Named pipes are used so that you can peek
                          ## at the process' output streams.
    poDemon               ## Windows: The program creates no Window.

  AsyncProcessObj = object of RootObj
    inPipe: AsyncPipe
    outPipe: AsyncPipe
    errPipe: AsyncPipe

    when defined(windows):
      fProcessHandle: Handle
      fThreadHandle: Handle
      procId: int32
      threadId: int32
      isWow64: bool
    else:
      procId: Pid
    isExit: bool
    exitCode: cint
    options: set[ProcessOption]

  AsyncProcess* = ref AsyncProcessObj ## represents an operating system process

proc quoteShellWindows*(s: string): string =
  ## Quote s, so it can be safely passed to Windows API.
  ##
  ## Based on Python's subprocess.list2cmdline
  ##
  ## See http://msdn.microsoft.com/en-us/library/17w5ykft.aspx
  let needQuote = {' ', '\t'} in s or s.len == 0

  result = ""
  var backslashBuff = ""
  if needQuote:
    result.add("\"")

  for c in s:
    if c == '\\':
      backslashBuff.add(c)
    elif c == '\"':
      result.add(backslashBuff)
      result.add(backslashBuff)
      backslashBuff.setLen(0)
      result.add("\\\"")
    else:
      if backslashBuff.len != 0:
        result.add(backslashBuff)
        backslashBuff.setLen(0)
      result.add(c)

  if needQuote:
    result.add("\"")

proc quoteShellPosix*(s: string): string =
  ## Quote ``s``, so it can be safely passed to POSIX shell.
  ##
  ## Based on Python's pipes.quote
  const safeUnixChars = {'%', '+', '-', '.', '/', '_', ':', '=', '@',
                         '0'..'9', 'A'..'Z', 'a'..'z'}
  if s.len == 0:
    return "''"

  let safe = s.allCharsInSet(safeUnixChars)

  if safe:
    return s
  else:
    return "'" & s.replace("'", "'\"'\"'") & "'"

proc quoteShell*(s: string): string =
  ## Quote ``s``, so it can be safely passed to shell.
  when defined(Windows):
    return quoteShellWindows(s)
  elif defined(posix):
    return quoteShellPosix(s)
  else:
    {.error:"quoteShell is not supported on your system".}


proc execProcess*(command: string, args: seq[string] = @[],
                  env: StringTableRef = nil,
                  options: set[ProcessOption] = {poStdErrToStdOut, poUsePath,
                                                poEvalCommand}
                 ): Future[tuple[exitcode: int, output: string]] {.async.}
  ## A convenience asynchronous procedure that executes ``command``
  ## with ``startProcess`` and returns its exit code and output as a tuple.
  ##
  ## **WARNING**: this function uses poEvalCommand by default for backward
  ## compatibility. Make sure to pass options explicitly.
  ##
  ## .. code-block:: Nim
  ##
  ##  let outp = await execProcess("nim c -r mytestfile.nim")
  ##  echo "process exited with code = " & $outp.exitcode
  ##  echo "process output = " & outp.output

proc startProcess*(command: string, workingDir: string = "",
                   args: openArray[string] = [],
                   env: StringTableRef = nil,
                   options: set[ProcessOption] = {poStdErrToStdOut},
                   pipeStdin: AsyncPipe = nil,
                   pipeStdout: AsyncPipe = nil,
                   pipeStderr: AsyncPipe = nil): AsyncProcess
  ## Starts a process.
  ##
  ## ``command`` is the executable file path
  ##
  ## ``workingDir`` is the process's working directory. If ``workingDir == ""``
  ## the current directory is used.
  ##
  ## ``args`` are the command line arguments that are passed to the
  ## process. On many operating systems, the first command line argument is the
  ## name of the executable. ``args`` should not contain this argument!
  ##
  ## ``env`` is the environment that will be passed to the process.
  ## If ``env == nil`` the environment is inherited of
  ## the parent process.
  ##
  ## ``options`` are additional flags that may be passed
  ## to `startProcess`.  See the documentation of ``ProcessOption`` for the
  ## meaning of these flags.
  ##
  ## ``pipeStdin``, ``pipeStdout``, ``pipeStderr``  is ``AsyncPipe`` handles
  ## which will be used as ``STDIN``, ``STDOUT`` and ``STDERR`` of started
  ## process respectively. This handles are optional, unspecified handles
  ## will be created automatically.
  ##
  ## Note that you can't pass any ``args`` if you use the option
  ## ``poEvalCommand``, which invokes the system shell to run the specified
  ## ``command``. In this situation you have to concatenate manually the
  ## contents of ``args`` to ``command`` carefully escaping/quoting any special
  ## characters, since it will be passed *as is* to the system shell.
  ## Each system/shell may feature different escaping rules, so try to avoid
  ## this kind of shell invocation if possible as it leads to non portable
  ## software.
  ##
  ## Return value: The newly created process object. Nil is never returned,
  ## but ``EOS`` is raised in case of an error.

proc suspend*(p: AsyncProcess)
  ## Suspends the process ``p``.
  ##
  ## On Posix OSes the procedure sends ``SIGSTOP`` signal to the process.
  ##
  ## On Windows procedure suspends main thread execution of process via
  ## ``SuspendThread()``. WOW64 processes is also supported.

proc resume*(p: AsyncProcess)
  ## Resumes the process ``p``.
  ##
  ## On Posix OSes the procedure sends ``SIGCONT`` signal to the process.
  ##
  ## On Windows procedure resumes execution of main thread via
  ## ``ResumeThread()``. WOW64 processes is also supported.

proc terminate*(p: AsyncProcess)
  ## Stop the process ``p``. On Posix OSes the procedure sends ``SIGTERM``
  ## to the process. On Windows the Win32 API function ``TerminateProcess()``
  ## is called to stop the process.

proc kill*(p: AsyncProcess)
  ## Kill the process ``p``. On Posix OSes the procedure sends ``SIGKILL`` to
  ## the process. On Windows ``kill()`` is simply an alias for ``terminate()``.

proc running*(p: AsyncProcess): bool
  ## Returns `true` if the process ``p`` is still running. Returns immediately.

proc peekExitCode*(p: AsyncProcess): int
  ## Returns `STILL_ACTIVE` if the process is still running.
  ## Otherwise the process' exit code.

proc processID*(p: AsyncProcess): int =
  ## Returns process ``p`` id.
  return p.procId

proc inputHandle*(p: AsyncProcess): AsyncPipe {.inline.} =
  ## Returns ``AsyncPipe`` handle to ``STDIN`` pipe of process ``p``.
  result = p.inPipe

proc outputHandle*(p: AsyncProcess): AsyncPipe {.inline.} =
  ## Returns ``AsyncPipe`` handle to ``STDOUT`` pipe of process ``p``.
  result = p.outPipe

proc errorHandle*(p: AsyncProcess): AsyncPipe {.inline.} =
  ## Returns ``AsyncPipe`` handle to ``STDERR`` pipe of process ``p``.
  result = p.errPipe

proc waitForExit*(p: AsyncProcess): Future[int]
  ## Waits for the process to finish in asynchronous way and returns
  ## exit code.

when defined(windows):

  const
    STILL_ACTIVE = 0x00000103'i32
    HANDLE_FLAG_INHERIT = 0x00000001'i32

  proc isWow64Process(hProcess: Handle, wow64Process: var WinBool): WinBool
       {.importc: "IsWow64Process", stdcall, dynlib: "kernel32".}
  proc wow64SuspendThread(hThread: Handle): Dword
       {.importc: "Wow64SuspendThread", stdcall, dynlib: "kernel32".}
  proc setHandleInformation(hObject: Handle, dwMask: Dword,
                            dwFlags: Dword): WinBool
       {.importc: "SetHandleInformation", stdcall, dynlib: "kernel32".}

  proc buildCommandLine(a: string, args: openArray[string]): cstring =
    var res = quoteShell(a)
    for i in 0..high(args):
      res.add(' ')
      res.add(quoteShell(args[i]))
    result = cast[cstring](alloc0(res.len+1))
    copyMem(result, cstring(res), res.len)

  proc buildEnv(env: StringTableRef): tuple[str: cstring, len: int] =
    var L = 0
    for key, val in pairs(env): inc(L, key.len + val.len + 2)
    var str = cast[cstring](alloc0(L+2))
    L = 0
    for key, val in pairs(env):
      var x = key & "=" & val
      copyMem(addr(str[L]), cstring(x), x.len+1) # copy \0
      inc(L, x.len+1)
    (str, L)

  proc close(p: AsyncProcess) =
    if p.inPipe != nil: close(p.inPipe)
    if p.outPipe != nil: close(p.outPipe)
    if p.errPipe != nil: close(p.errPipe)

  proc startProcess(command: string, workingDir: string = "",
                    args: openArray[string] = [],
                    env: StringTableRef = nil,
                    options: set[ProcessOption] = {poStdErrToStdOut},
                    pipeStdin: AsyncPipe = nil,
                    pipeStdout: AsyncPipe = nil,
                    pipeStderr: AsyncPipe = nil): AsyncProcess =
    var
      si: STARTUPINFO
      procInfo: PROCESS_INFORMATION

    result = AsyncProcess(options: options, isExit: true)
    si.cb = sizeof(STARTUPINFO).cint

    if not isNil(pipeStdin):
      si.hStdInput = pipeStdin.getReadHandle()

      # Mark other side of pipe as non inheritable.
      let oh = pipeStdin.getWriteHandle()
      if oh != 0:
        if setHandleInformation(oh, HANDLE_FLAG_INHERIT, 0) == 0:
          raiseOSError(osLastError())
    else:
      if poParentStreams in options:
        si.hStdInput = getStdHandle(STD_INPUT_HANDLE)
      else:
        let pipe = createPipe()
        if poInteractive in options:
          result.inPipe = pipe
          si.hStdInput = pipe.getReadHandle()
        else:
          result.inPipe = pipe
          si.hStdInput = pipe.getReadHandle()

        if setHandleInformation(pipe.getWriteHandle(),
                                HANDLE_FLAG_INHERIT, 0) == 0:
          raiseOSError(osLastError())

    if not isNil(pipeStdout):
      si.hStdOutput = pipeStdout.getWriteHandle()

      # Mark other side of pipe as non inheritable.
      let oh = pipeStdout.getReadHandle()
      if oh != 0:
        if setHandleInformation(oh, HANDLE_FLAG_INHERIT, 0) == 0:
          raiseOSError(osLastError())
    else:
      if poParentStreams in options:
        si.hStdOutput = getStdHandle(STD_OUTPUT_HANDLE)
      else:
        let pipe = createPipe()
        if poInteractive in options:
          result.outPipe = pipe
          si.hStdOutput = pipe.getWriteHandle()
        else:
          result.outPipe = pipe
          si.hStdOutput = pipe.getWriteHandle()
        if setHandleInformation(pipe.getReadHandle(),
                                HANDLE_FLAG_INHERIT, 0) == 0:
          raiseOSError(osLastError())

    if not isNil(pipeStderr):
      si.hStdError = pipeStderr.getWriteHandle()

      # Mark other side of pipe as non inheritable.
      let oh = pipeStderr.getReadHandle()
      if oh != 0:
        if setHandleInformation(oh, HANDLE_FLAG_INHERIT, 0) == 0:
          raiseOSError(osLastError())
    else:
      if poParentStreams in options:
        si.hStdError = getStdHandle(STD_ERROR_HANDLE)
      else:
        if poInteractive in options:
          let pipe = createPipe()
          result.errPipe = pipe
          si.hStdError = pipe.getWriteHandle()
          if setHandleInformation(pipe.getReadHandle(),
                                  HANDLE_FLAG_INHERIT, 0) == 0:
            raiseOSError(osLastError())
        else:
          if poStdErrToStdOut in options:
            result.errPipe = result.outPipe
            si.hStdError = si.hStdOutput
          else:
            let pipe = createPipe()
            result.errPipe = pipe
            si.hStdError = pipe.getWriteHandle()
            if setHandleInformation(pipe.getReadHandle(),
                                    HANDLE_FLAG_INHERIT, 0) == 0:
              raiseOSError(osLastError())

    if si.hStdInput != 0 or si.hStdOutput != 0 or si.hStdError != 0:
      si.dwFlags = STARTF_USESTDHANDLES

    # building command line
    var cmdl: cstring
    if poEvalCommand in options:
      cmdl = buildCommandLine("cmd.exe", ["/c", command])
      assert args.len == 0
    else:
      cmdl = buildCommandLine(command, args)
    # building environment
    var e = (str: nil.cstring, len: -1)
    if env != nil: e = buildEnv(env)
    # building working directory
    var wd: cstring = nil
    if len(workingDir) > 0: wd = workingDir
    # processing echo command line
    if poEchoCmd in options: echo($cmdl)
    # building security attributes for process and main thread
    var psa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).cint,
                                  lpSecurityDescriptor: nil, bInheritHandle: 1)
    var tsa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).cint,
                                  lpSecurityDescriptor: nil, bInheritHandle: 1)

    var tmp = newWideCString(cmdl)
    var ee =
      if e.str.isNil: newWideCString(cstring(nil))
      else: newWideCString(e.str, e.len)
    var wwd = newWideCString(wd)
    var flags = NORMAL_PRIORITY_CLASS or CREATE_UNICODE_ENVIRONMENT
    if poDemon in options: flags = flags or CREATE_NO_WINDOW
    let res = winlean.createProcessW(nil, tmp, addr psa, addr tsa, 1, flags,
                                     ee, wwd, si, procInfo)
    if e.str != nil: dealloc(e.str)
    if res == 0:
      close(result)
      raiseOsError(osLastError())
    else:
      result.fProcessHandle = procInfo.hProcess
      result.procId = procInfo.dwProcessId
      result.fThreadHandle = procInfo.hThread
      result.threadId = procInfo.dwThreadId
      when sizeof(int) == 8:
        # If sizeof(int) == 8, then our process is 64bit, and we need to check
        # architecture of just spawned process.
        var iswow64 = WinBool(0)
        if isWow64Process(procInfo.hProcess, iswow64) == 0:
          raiseOsError(osLastError())
        result.isWow64 = (iswow64 != 0)
      else:
        result.isWow64 = false

      result.isExit = false

      if poParentStreams notin options:
        closeRead(result.inPipe)
        closeWrite(result.outPipe)
        closeWrite(result.errPipe)

  proc suspend(p: AsyncProcess) =
    var res = 0'i32
    if p.isWow64:
      res = wow64SuspendThread(p.fThreadHandle)
    else:
      res = suspendThread(p.fThreadHandle)
    if res < 0:
      raiseOsError(osLastError())

  proc resume(p: AsyncProcess) =
    let res = resumeThread(p.fThreadHandle)
    if res < 0:
      raiseOsError(osLastError())

  proc running(p: AsyncProcess): bool =
    var value = 0'i32
    let res = getExitCodeProcess(p.fProcessHandle, value)
    if res == 0:
      raiseOsError(osLastError())
    else:
      if value == STILL_ACTIVE:
        result = true
      else:
        p.isExit = true
        p.exitCode = value

  proc terminate(p: AsyncProcess) =
    if running(p):
      discard terminateProcess(p.fProcessHandle, 0)

  proc kill(p: AsyncProcess) =
    terminate(p)

  proc peekExitCode(p: AsyncProcess): int =
    if p.isExit:
      result = p.exitCode
    else:
      var value = 0'i32
      let res = getExitCodeProcess(p.fProcessHandle, value)
      if res == 0:
        raiseOsError(osLastError())
      else:
        result = value
        if value != STILL_ACTIVE:
          p.isExit = true
          p.exitCode = value

  when declared(addProcess):
    proc waitForExit(p: AsyncProcess): Future[int] =
      var retFuture = newFuture[int]("asyncproc.waitForExit")

      proc cb(fd: AsyncFD): bool =
        var value = 0'i32
        let res = getExitCodeProcess(p.fProcessHandle, value)
        if res == 0:
          retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
        else:
          p.isExit = true
          p.exitCode = value
          retFuture.complete(p.exitCode)

      if p.isExit:
        retFuture.complete(p.exitCode)
      else:
        addProcess(p.procId, cb)
      return retFuture

else:
  const
    readIdx = 0
    writeIdx = 1

  template statusToExitCode(status): int32 =
    (status and 0xFF00) shr 8

  proc envToCStringArray(t: StringTableRef): cstringArray =
    result = cast[cstringArray](alloc0((t.len + 1) * sizeof(cstring)))
    var i = 0
    for key, val in pairs(t):
      var x = key & "=" & val
      result[i] = cast[cstring](alloc(x.len+1))
      copyMem(result[i], addr(x[0]), x.len+1)
      inc(i)

  proc envToCStringArray(): cstringArray =
    var counter = 0
    for key, val in envPairs(): inc counter
    result = cast[cstringArray](alloc0((counter + 1) * sizeof(cstring)))
    var i = 0
    for key, val in envPairs():
      var x = key.string & "=" & val.string
      result[i] = cast[cstring](alloc(x.len+1))
      copyMem(result[i], addr(x[0]), x.len+1)
      inc(i)

  type StartProcessData = object
    sysCommand: cstring
    sysArgs: cstringArray
    sysEnv: cstringArray
    workingDir: cstring
    pStdin, pStdout, pStderr, pErrorPipe: array[0..1, cint]
    options: set[ProcessOption]

  const useProcessAuxSpawn = declared(posix_spawn) and not defined(useFork) and
                             not defined(useClone) and not defined(linux)
  when useProcessAuxSpawn:
    proc startProcessAuxSpawn(data: StartProcessData): Pid {.
      tags: [ExecIOEffect, ReadEnvEffect], gcsafe.}
  else:
    proc startProcessAuxFork(data: StartProcessData): Pid {.
      tags: [ExecIOEffect, ReadEnvEffect], gcsafe.}

    {.push stacktrace: off, profiler: off.}
    proc startProcessAfterFork(data: ptr StartProcessData) {.
      tags: [ExecIOEffect, ReadEnvEffect], cdecl, gcsafe.}
    {.pop.}

  proc startProcess(command: string, workingDir: string = "",
                    args: openArray[string] = [],
                    env: StringTableRef = nil,
                    options: set[ProcessOption] = {poStdErrToStdOut},
                    pipeStdin: AsyncPipe = nil,
                    pipeStdout: AsyncPipe = nil,
                    pipeStderr: AsyncPipe = nil): AsyncProcess =
    var sd = StartProcessData()

    result = AsyncProcess(options: options, isExit: true)

    if not isNil(pipeStdin):
      sd.pStdin = pipeStdin.getHandles()
    else:
      if poParentStreams notin options:
        let pipe = createPipe()
        sd.pStdin = pipe.getHandles()
        result.inPipe = pipe

    if not isNil(pipeStdout):
      sd.pStdout = pipeStdout.getHandles()
    else:
      if poParentStreams notin options:
        let pipe = createPipe()
        sd.pStdout = pipe.getHandles()
        result.outPipe = pipe

    if not isNil(pipeStderr):
      sd.pStderr = pipeStderr.getHandles()
    else:
      if poParentStreams notin options:
        if poStdErrToStdOut in options:
          sd.pStderr = sd.pStdout
          result.errPipe = result.outPipe
        else:
          let pipe = createPipe()
          sd.pStderr = pipe.getHandles()
          result.errPipe = pipe

    var sysCommand: string
    var sysArgsRaw: seq[string]

    if poEvalCommand in options:
      sysCommand = "/bin/sh"
      sysArgsRaw = @[sysCommand, "-c", command]
      assert args.len == 0, "`args` has to be empty when using poEvalCommand."
    else:
      sysCommand = command
      sysArgsRaw = @[command]
      for arg in args.items:
        sysArgsRaw.add arg

    var pid: Pid

    var sysArgs = allocCStringArray(sysArgsRaw)
    defer: deallocCStringArray(sysArgs)

    var sysEnv = if env == nil:
        envToCStringArray()
      else:
        envToCStringArray(env)
    defer: deallocCStringArray(sysEnv)

    sd.sysCommand = sysCommand
    sd.sysArgs = sysArgs
    sd.sysEnv = sysEnv
    sd.options = options
    sd.workingDir = workingDir

    when useProcessAuxSpawn:
      let currentDir = getCurrentDir()
      pid = startProcessAuxSpawn(sd)
      if workingDir.len > 0:
        setCurrentDir(currentDir)
    else:
      pid = startProcessAuxFork(sd)

    # Parent process. Copy process information.
    if poEchoCmd in options:
      echo(command, " ", join(args, " "))
    result.procId = pid

    result.isExit = false

    if poParentStreams notin options:
      closeRead(result.inPipe)
      closeWrite(result.outPipe)
      closeWrite(result.errPipe)

  when useProcessAuxSpawn:
    proc startProcessAuxSpawn(data: StartProcessData): Pid =
      var attr: Tposix_spawnattr
      var fops: Tposix_spawn_file_actions

      template chck(e: untyped) =
        if e != 0'i32: raiseOSError(osLastError())

      chck posix_spawn_file_actions_init(fops)
      chck posix_spawnattr_init(attr)

      var mask: Sigset
      chck sigemptyset(mask)
      chck posix_spawnattr_setsigmask(attr, mask)

      var flags = POSIX_SPAWN_USEVFORK or POSIX_SPAWN_SETSIGMASK
      if poDemon in data.options:
        flags = flags or POSIX_SPAWN_SETPGROUP
        chck posix_spawnattr_setpgroup(attr, 0'i32)

      chck posix_spawnattr_setflags(attr, flags)

      if not (poParentStreams in data.options):
        chck posix_spawn_file_actions_addclose(fops, data.pStdin[writeIdx])
        chck posix_spawn_file_actions_adddup2(fops, data.pStdin[readIdx],
                                              readIdx)
        chck posix_spawn_file_actions_addclose(fops, data.pStdout[readIdx])
        chck posix_spawn_file_actions_adddup2(fops, data.pStdout[writeIdx],
                                              writeIdx)
        if (poStdErrToStdOut in data.options):
          chck posix_spawn_file_actions_adddup2(fops, data.pStdout[writeIdx], 2)
        else:
          chck posix_spawn_file_actions_addclose(fops, data.pStderr[readIdx])
          chck posix_spawn_file_actions_adddup2(fops, data.pStderr[writeIdx], 2)

      var res: cint
      if data.workingDir.len > 0:
        setCurrentDir($data.workingDir)
      var pid: Pid

      if (poUsePath in data.options):
        res = posix_spawnp(pid, data.sysCommand, fops, attr, data.sysArgs,
                           data.sysEnv)
      else:
        res = posix_spawn(pid, data.sysCommand, fops, attr, data.sysArgs,
                          data.sysEnv)

      discard posix_spawn_file_actions_destroy(fops)
      discard posix_spawnattr_destroy(attr)
      chck res
      return pid
  else:
    proc startProcessAuxFork(data: StartProcessData): Pid =
      if pipe(data.pErrorPipe) != 0:
        raiseOSError(osLastError())

      defer:
        discard close(data.pErrorPipe[readIdx])

      var pid: Pid
      var dataCopy = data

      when defined(useClone):
        const stackSize = 65536
        let stackEnd = cast[clong](alloc(stackSize))
        let stack = cast[pointer](stackEnd + stackSize)
        let fn: pointer = startProcessAfterFork
        pid = clone(fn, stack,
                    cint(CLONE_VM or CLONE_VFORK or SIGCHLD),
                    pointer(addr dataCopy), nil, nil, nil)
        discard close(data.pErrorPipe[writeIdx])
        dealloc(stack)
      else:
        pid = fork()
        if pid == 0:
          startProcessAfterFork(addr(dataCopy))
          exitnow(1)

      discard close(data.pErrorPipe[writeIdx])
      if pid < 0: raiseOSError(osLastError())

      var error: cint

      var res = read(data.pErrorPipe[readIdx], addr error, sizeof(error))
      if res == sizeof(error):
        raiseOSError(osLastError(),
                     "Could not find command: '$1'. OS error: $2" %
                     [$data.sysCommand, $strerror(error)])
      return pid

    {.push stacktrace: off, profiler: off.}
    proc startProcessFail(data: ptr StartProcessData) =
      var error: cint = errno
      discard write(data.pErrorPipe[writeIdx], addr error, sizeof(error))
      exitnow(1)

    when not defined(uClibc) and (not defined(linux) or defined(android)):
      var environ {.importc.}: cstringArray

    proc startProcessAfterFork(data: ptr StartProcessData) =
      # Warning: no GC here!
      # Or anything that touches global structures - all called nim procs
      # must be marked with stackTrace:off. Inspect C code after making changes.
      if (poDemon in data.options):
        if posix.setpgid(Pid(0), Pid(0)) != 0:
          startProcessFail(data)

      if not (poParentStreams in data.options):
        if posix.close(data.pStdin[writeIdx]) != 0:
          startProcessFail(data)

        if dup2(data.pStdin[readIdx], readIdx) < 0:
          startProcessFail(data)

        if posix.close(data.pStdout[readIdx]) != 0:
          startProcessFail(data)

        if dup2(data.pStdout[writeIdx], writeIdx) < 0:
          startProcessFail(data)

        if (poStdErrToStdOut in data.options):
          if dup2(data.pStdout[writeIdx], 2) < 0:
            startProcessFail(data)
        else:
          if posix.close(data.pStderr[readIdx]) != 0:
            startProcessFail(data)

          if dup2(data.pStderr[writeIdx], 2) < 0:
            startProcessFail(data)

      if data.workingDir.len > 0:
        if chdir(data.workingDir) < 0:
          startProcessFail(data)

      if posix.close(data.pErrorPipe[readIdx]) != 0:
        startProcessFail(data)

      discard fcntl(data.pErrorPipe[writeIdx], F_SETFD, FD_CLOEXEC)

      if (poUsePath in data.options):
        when defined(uClibc):
          # uClibc environment (OpenWrt included) doesn't have the full execvpe
          discard execve(data.sysCommand, data.sysArgs, data.sysEnv)
        elif defined(linux) and not defined(android):
          discard execvpe(data.sysCommand, data.sysArgs, data.sysEnv)
        else:
          # MacOSX doesn't have execvpe, so we need workaround.
          # On MacOSX we can arrive here only from fork, so this is safe:
          environ = data.sysEnv
          discard execvp(data.sysCommand, data.sysArgs)
      else:
        discard execve(data.sysCommand, data.sysArgs, data.sysEnv)

      startProcessFail(data)
    {.pop}

  proc close(p: AsyncProcess) =
    ## We need to `wait` for process, to avoid `zombie`, so if `running()`
    ## returns `false`, then process exited and `wait()` was called.
    doAssert(not p.running())
    if p.inPipe != nil: close(p.inPipe)
    if p.outPipe != nil: close(p.outPipe)
    if p.errPipe != nil: close(p.errPipe)

  proc running(p: AsyncProcess): bool =
    result = true
    if p.isExit:
      result = false
    else:
      var status = cint(0)
      let res = posix.waitpid(p.procId, status, WNOHANG)
      if res == 0:
        result = true
      elif res < 0:
        raiseOsError(osLastError())
      else:
        if WIFEXITED(status) or WIFSIGNALED(status):
          p.isExit = true
          p.exitCode = statusToExitCode(status)
          result = false

  proc peekExitCode(p: AsyncProcess): int =
    if p.isExit:
      result = p.exitCode
    else:
      var status = cint(0)
      let res = posix.waitpid(p.procId, status, WNOHANG)
      if res < 0:
        raiseOsError(osLastError())
      elif res > 0:
        p.isExit = true
        p.exitCode = statusToExitCode(status)
        result = p.exitCode
      else:
        result = STILL_ACTIVE

  proc suspend(p: AsyncProcess) =
    if posix.kill(p.procId, SIGSTOP) != 0'i32:
      raiseOsError(osLastError())

  proc resume(p: AsyncProcess) =
    if posix.kill(p.procId, SIGCONT) != 0'i32:
      raiseOsError(osLastError())

  proc terminate(p: AsyncProcess) =
    if posix.kill(p.procId, SIGTERM) != 0'i32:
      raiseOsError(osLastError())

  proc kill(p: AsyncProcess) =
    if posix.kill(p.procId, SIGKILL) != 0'i32:
      raiseOsError(osLastError())

  when declared(addProcess):
    proc waitForExit*(p: AsyncProcess): Future[int] =
      var retFuture = newFuture[int]("asyncproc.waitForExit")

      proc cb(fd: AsyncFD): bool =
        var status = cint(0)
        let res = posix.waitpid(p.procId, status, WNOHANG)
        if res <= 0:
          retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
        else:
          p.isExit = true
          p.exitCode = statusToExitCode(status)
          retFuture.complete(p.exitCode)

      if p.isExit:
        retFuture.complete(p.exitCode)
      else:
        while true:
          var status = cint(0)
          let res = posix.waitpid(p.procId, status, WNOHANG)
          if res < 0:
            retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
            break
          elif res > 0:
            p.isExit = true
            p.exitCode = statusToExitCode(status)
            retFuture.complete(p.exitCode)
            break
          else:
            try:
              addProcess(p.procId, cb)
              break
            except:
              let err = osLastError()
              if cint(err) == ESRCH:
                continue
              else:
                retFuture.fail(newException(OSError, osErrorMsg(err)))
                break
      return retFuture

proc execProcess(command: string, args: seq[string] = @[],
                 env: StringTableRef = nil,
                 options: set[ProcessOption] = {poStdErrToStdOut, poUsePath,
                                                poEvalCommand}
                ): Future[tuple[exitcode: int, output: string]] {.async.} =
  result = (exitcode: int(STILL_ACTIVE), output: "")
  let bufferSize = 1024
  var data = newString(bufferSize)
  var p = startProcess(command, args = args, env = env, options = options)

  while true:
    let res = await p.outputHandle.readInto(addr data[0], bufferSize)
    if res > 0:
      data.setLen(res)
      result.output &= data
      data.setLen(bufferSize)
    else:
      break
  result.exitcode = await p.waitForExit()
  close(p)

when isMainModule:
  import os

  when defined(windows):
    var data = waitFor(execProcess("cd"))
  else:
    var data = waitFor(execProcess("pwd"))
  echo "exitCode = " & $data.exitcode
  echo "output = [" & $data.output & "]"
