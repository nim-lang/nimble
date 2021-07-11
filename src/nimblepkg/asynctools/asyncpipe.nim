#
#
#       Asynchronous tools for Nim Language
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

## This module implements cross-platform asynchronous pipes communication.
##
## Module uses named pipes for Windows, and anonymous pipes for
## Linux/BSD/MacOS.
##
## .. code-block:: nim
##   var inBuffer = newString(64)
##   var outBuffer = "TEST STRING BUFFER"
##
##   # Create new pipe
##   var o = createPipe()
##
##   # Write string to pipe
##   waitFor write(o, cast[pointer](addr outBuffer[0]), outBuffer.len)
##
##   # Read data from pipe
##   var c = waitFor readInto(o, cast[pointer](addr inBuffer[0]), inBuffer.len)
##
##   inBuffer.setLen(c)
##   doAssert(inBuffer == outBuffer)
##
##   # Close pipe
##   close(o)

import asyncdispatch, os

when defined(nimdoc):
  type
    AsyncPipe* = ref object ## Object represents ``AsyncPipe``.

  proc createPipe*(register = true): AsyncPipe =
    ## Create descriptor pair for interprocess communication.
    ##
    ## Returns ``AsyncPipe`` object, which represents OS specific pipe.
    ##
    ## If ``register`` is `false`, both pipes will not be registered with
    ## current dispatcher.

  proc closeRead*(pipe: AsyncPipe, unregister = true) =
    ## Closes read side of pipe ``pipe``.
    ##
    ## If ``unregister`` is `false`, pipe will not be unregistered from
    ## current dispatcher.

  proc closeWrite*(pipe: AsyncPipe, unregister = true) =
    ## Closes write side of pipe ``pipe``.
    ##
    ## If ``unregister`` is `false`, pipe will not be unregistered from
    ## current dispatcher.

  proc getReadHandle*(pipe: AsyncPipe): int =
    ## Returns OS specific handle for read side of pipe ``pipe``.

  proc getWriteHandle*(pipe: AsyncPipe): int =
    ## Returns OS specific handle for write side of pipe ``pipe``.

  proc getHandles*(pipe: AsyncPipe): array[2, Handle] =
    ## Returns OS specific handles of ``pipe``.

  proc getHandles*(pipe: AsyncPipe): array[2, cint] =
    ## Returns OS specific handles of ``pipe``.

  proc close*(pipe: AsyncPipe, unregister = true) =
    ## Closes both ends of pipe ``pipe``.
    ##
    ## If ``unregister`` is `false`, pipe will not be unregistered from
    ## current dispatcher.

  proc write*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[int] =
    ## This procedure writes an untyped ``data`` of ``size`` size to the
    ## pipe ``pipe``.
    ##
    ## The returned future will complete once ``all`` data has been sent or
    ## part of the data has been sent.

  proc readInto*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[int] =
    ## This procedure reads up to ``size`` bytes from pipe ``pipe``
    ## into ``data``, which must at least be of that size.
    ##
    ## Returned future will complete once all the data requested is read or
    ## part of the data has been read.

  proc asyncWrap*(readHandle: Handle|cint = 0,
                  writeHandle: Handle|cint = 0): AsyncPipe =
    ## Wraps existing OS specific pipe handles to ``AsyncPipe`` and register
    ## it with current dispatcher.
    ##
    ## ``readHandle`` - read side of pipe (optional value).
    ## ``writeHandle`` - write side of pipe (optional value).
    ## **Note**: At least one handle must be specified.
    ##
    ## Returns ``AsyncPipe`` object.
    ##
    ## Windows handles must be named pipes created with ``CreateNamedPipe`` and
    ## ``FILE_FLAG_OVERLAPPED`` in flags. You can use ``ReopenFile()`` function
    ## to convert existing handle to overlapped variant.
    ##
    ## Posix handle will be modified with ``O_NONBLOCK``.

  proc asyncUnwrap*(pipe: AsyncPipe) =
    ## Unregisters ``pipe`` handle from current async dispatcher.

  proc `$`*(pipe: AsyncPipe) =
    ## Returns string representation of ``AsyncPipe`` object.

else:

  when defined(windows):
    import winlean
  else:
    import posix

  type
    AsyncPipe* = ref object of RootRef
      when defined(windows):
        readPipe: Handle
        writePipe: Handle
      else:
        readPipe: cint
        writePipe: cint

  when defined(windows):

    proc QueryPerformanceCounter(res: var int64)
         {.importc: "QueryPerformanceCounter", stdcall, dynlib: "kernel32".}
    proc connectNamedPipe(hNamedPipe: Handle, lpOverlapped: pointer): WINBOOL
         {.importc: "ConnectNamedPipe", stdcall, dynlib: "kernel32".}

    when not declared(PCustomOverlapped):
      type
        PCustomOverlapped = CustomRef

    const
      pipeHeaderName = r"\\.\pipe\asyncpipe_"

    const
      DEFAULT_PIPE_SIZE = 65536'i32
      FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000'i32
      PIPE_WAIT = 0x00000000'i32
      PIPE_TYPE_BYTE = 0x00000000'i32
      PIPE_READMODE_BYTE = 0x00000000'i32
      ERROR_PIPE_CONNECTED = 535
      ERROR_PIPE_BUSY = 231
      ERROR_BROKEN_PIPE = 109
      ERROR_PIPE_NOT_CONNECTED = 233

    proc `$`*(pipe: AsyncPipe): string =
      result = "AsyncPipe [read = " & $(cast[uint](pipe.readPipe)) &
               ", write = " & $(cast[int](pipe.writePipe)) & "]"

    proc createPipe*(register = true): AsyncPipe =

      var number = 0'i64
      var pipeName: WideCString
      var pipeIn: Handle
      var pipeOut: Handle
      var sa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).cint,
                                   lpSecurityDescriptor: nil, bInheritHandle: 1)
      while true:
        QueryPerformanceCounter(number)
        let p = pipeHeaderName & $number
        pipeName = newWideCString(p)
        var openMode = FILE_FLAG_FIRST_PIPE_INSTANCE or FILE_FLAG_OVERLAPPED or
                       PIPE_ACCESS_INBOUND
        var pipeMode = PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT
        pipeIn = createNamedPipe(pipeName, openMode, pipeMode, 1'i32,
                                 DEFAULT_PIPE_SIZE, DEFAULT_PIPE_SIZE,
                                 1'i32, addr sa)
        if pipeIn == INVALID_HANDLE_VALUE:
          let err = osLastError()
          if err.int32 != ERROR_PIPE_BUSY:
            raiseOsError(err)
        else:
          break

      var openMode = (FILE_WRITE_DATA or SYNCHRONIZE)
      pipeOut = createFileW(pipeName, openMode, 0, addr(sa), OPEN_EXISTING,
                            FILE_FLAG_OVERLAPPED, 0)
      if pipeOut == INVALID_HANDLE_VALUE:
        let err = osLastError()
        discard closeHandle(pipeIn)
        raiseOsError(err)

      result = AsyncPipe(readPipe: pipeIn, writePipe: pipeOut)

      var ovl = OVERLAPPED()
      let res = connectNamedPipe(pipeIn, cast[pointer](addr ovl))
      if res == 0:
        let err = osLastError()
        if err.int32 == ERROR_PIPE_CONNECTED:
          discard
        elif err.int32 == ERROR_IO_PENDING:
          var bytesRead = 0.Dword
          if getOverlappedResult(pipeIn, addr ovl, bytesRead, 1) == 0:
            let oerr = osLastError()
            discard closeHandle(pipeIn)
            discard closeHandle(pipeOut)
            raiseOsError(oerr)
        else:
          discard closeHandle(pipeIn)
          discard closeHandle(pipeOut)
          raiseOsError(err)

      if register:
        register(AsyncFD(pipeIn))
        register(AsyncFD(pipeOut))

    proc asyncWrap*(readHandle = Handle(0),
                    writeHandle = Handle(0)): AsyncPipe =
      doAssert(readHandle != 0 or writeHandle != 0)

      result = AsyncPipe(readPipe: readHandle, writePipe: writeHandle)
      if result.readPipe != 0:
        register(AsyncFD(result.readPipe))
      if result.writePipe != 0:
        register(AsyncFD(result.writePipe))

    proc asyncUnwrap*(pipe: AsyncPipe) =
      if pipe.readPipe != 0:
        unregister(AsyncFD(pipe.readPipe))
      if pipe.writePipe != 0:
        unregister(AsyncFD(pipe.writePipe))

    proc getReadHandle*(pipe: AsyncPipe): Handle {.inline.} =
      result = pipe.readPipe

    proc getWriteHandle*(pipe: AsyncPipe): Handle {.inline.} =
      result = pipe.writePipe

    proc getHandles*(pipe: AsyncPipe): array[2, Handle] {.inline.} =
      result = [pipe.readPipe, pipe.writePipe]

    proc closeRead*(pipe: AsyncPipe, unregister = true) =
      if pipe.readPipe != 0:
        if unregister:
          unregister(AsyncFD(pipe.readPipe))
        if closeHandle(pipe.readPipe) == 0:
          raiseOsError(osLastError())
        pipe.readPipe = 0

    proc closeWrite*(pipe: AsyncPipe, unregister = true) =
      if pipe.writePipe != 0:
        if unregister:
          unregister(AsyncFD(pipe.writePipe))
        if closeHandle(pipe.writePipe) == 0:
          raiseOsError(osLastError())
        pipe.writePipe = 0

    proc close*(pipe: AsyncPipe, unregister = true) =
      closeRead(pipe, unregister)
      closeWrite(pipe, unregister)

    proc write*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[int] =
      var retFuture = newFuture[int]("asyncpipe.write")
      var ol = PCustomOverlapped()

      if pipe.writePipe == 0:
        retFuture.fail(newException(ValueError,
                                  "Write side of pipe closed or not available"))
      else:
        GC_ref(ol)
        ol.data = CompletionData(fd: AsyncFD(pipe.writePipe), cb:
          proc (fd: AsyncFD, bytesCount: DWord, errcode: OSErrorCode) =
            if not retFuture.finished:
              if errcode == OSErrorCode(-1):
                retFuture.complete(bytesCount)
              else:
                retFuture.fail(newException(OSError, osErrorMsg(errcode)))
        )
        let res = writeFile(pipe.writePipe, data, nbytes.int32, nil,
                            cast[POVERLAPPED](ol)).bool
        if not res:
          let errcode = osLastError()
          if errcode.int32 != ERROR_IO_PENDING:
            GC_unref(ol)
            retFuture.fail(newException(OSError, osErrorMsg(errcode)))
      return retFuture

    proc readInto*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[int] =
      var retFuture = newFuture[int]("asyncpipe.readInto")
      var ol = PCustomOverlapped()

      if pipe.readPipe == 0:
        retFuture.fail(newException(ValueError,
                                   "Read side of pipe closed or not available"))
      else:
        GC_ref(ol)
        ol.data = CompletionData(fd: AsyncFD(pipe.readPipe), cb:
          proc (fd: AsyncFD, bytesCount: DWord, errcode: OSErrorCode) =
            if not retFuture.finished:
              if errcode == OSErrorCode(-1):
                assert(bytesCount > 0 and bytesCount <= nbytes.int32)
                retFuture.complete(bytesCount)
              else:
                if errcode.int32 in {ERROR_BROKEN_PIPE,
                                     ERROR_PIPE_NOT_CONNECTED}:
                  retFuture.complete(bytesCount)
                else:
                  retFuture.fail(newException(OSError, osErrorMsg(errcode)))
        )
        let res = readFile(pipe.readPipe, data, nbytes.int32, nil,
                           cast[POVERLAPPED](ol)).bool
        if not res:
          let err = osLastError()
          if err.int32 in {ERROR_BROKEN_PIPE, ERROR_PIPE_NOT_CONNECTED}:
            GC_unref(ol)
            retFuture.complete(0)
          elif err.int32 != ERROR_IO_PENDING:
            GC_unref(ol)
            retFuture.fail(newException(OSError, osErrorMsg(err)))
      return retFuture
  else:

    proc setNonBlocking(fd: cint) {.inline.} =
      var x = fcntl(fd, F_GETFL, 0)
      if x == -1:
        raiseOSError(osLastError())
      else:
        var mode = x or O_NONBLOCK
        if fcntl(fd, F_SETFL, mode) == -1:
          raiseOSError(osLastError())

    proc `$`*(pipe: AsyncPipe): string =
      result = "AsyncPipe [read = " & $(cast[uint](pipe.readPipe)) &
                ", write = " & $(cast[uint](pipe.writePipe)) & "]"

    proc createPipe*(size = 65536, register = true): AsyncPipe =
      var fds: array[2, cint]
      if posix.pipe(fds) == -1:
        raiseOSError(osLastError())
      setNonBlocking(fds[0])
      setNonBlocking(fds[1])

      result = AsyncPipe(readPipe: fds[0], writePipe: fds[1])

      if register:
        register(AsyncFD(fds[0]))
        register(AsyncFD(fds[1]))

    proc asyncWrap*(readHandle = cint(0), writeHandle = cint(0)): AsyncPipe =
      doAssert((readHandle != 0) or (writeHandle != 0))
      result = AsyncPipe(readPipe: readHandle, writePipe: writeHandle)
      if result.readPipe != 0:
        setNonBlocking(result.readPipe)
        register(AsyncFD(result.readPipe))
      if result.writePipe != 0:
        setNonBlocking(result.writePipe)
        register(AsyncFD(result.writePipe))

    proc asyncUnwrap*(pipe: AsyncPipe) =
      if pipe.readPipe != 0:
        unregister(AsyncFD(pipe.readPipe))
      if pipe.writePipe != 0:
        unregister(AsyncFD(pipe.writePipe))

    proc getReadHandle*(pipe: AsyncPipe): cint {.inline.} =
      result = pipe.readPipe

    proc getWriteHandle*(pipe: AsyncPipe): cint {.inline.} =
      result = pipe.writePipe

    proc getHandles*(pipe: AsyncPipe): array[2, cint] {.inline.} =
      result = [pipe.readPipe, pipe.writePipe]

    proc closeRead*(pipe: AsyncPipe, unregister = true) =
      if pipe.readPipe != 0:
        if unregister:
          unregister(AsyncFD(pipe.readPipe))
        if posix.close(cint(pipe.readPipe)) != 0:
          raiseOSError(osLastError())
        pipe.readPipe = 0

    proc closeWrite*(pipe: AsyncPipe, unregister = true) =
      if pipe.writePipe != 0:
        if unregister:
          unregister(AsyncFD(pipe.writePipe))
        if posix.close(cint(pipe.writePipe)) != 0:
          raiseOSError(osLastError())
        pipe.writePipe = 0

    proc close*(pipe: AsyncPipe, unregister = true) =
      closeRead(pipe, unregister)
      closeWrite(pipe, unregister)

    proc write*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[int] =
      var retFuture = newFuture[int]("asyncpipe.write")
      var bytesWrote = 0

      proc cb(fd: AsyncFD): bool =
        result = true
        let reminder = nbytes - bytesWrote
        let pdata = cast[pointer](cast[uint](data) + bytesWrote.uint)
        let res = posix.write(pipe.writePipe, pdata, cint(reminder))
        if res < 0:
          let err = osLastError()
          if err.int32 != EAGAIN:
            retFuture.fail(newException(OSError, osErrorMsg(err)))
          else:
            result = false # We still want this callback to be called.
        elif res == 0:
          retFuture.complete(bytesWrote)
        else:
          bytesWrote.inc(res)
          if res != reminder:
            result = false
          else:
            retFuture.complete(bytesWrote)

      if pipe.writePipe == 0:
        retFuture.fail(newException(ValueError,
                                  "Write side of pipe closed or not available"))
      else:
        if not cb(AsyncFD(pipe.writePipe)):
          addWrite(AsyncFD(pipe.writePipe), cb)
      return retFuture

    proc readInto*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[int] =
      var retFuture = newFuture[int]("asyncpipe.readInto")
      proc cb(fd: AsyncFD): bool =
        result = true
        let res = posix.read(pipe.readPipe, data, cint(nbytes))
        if res < 0:
          let err = osLastError()
          if err.int32 != EAGAIN:
            retFuture.fail(newException(OSError, osErrorMsg(err)))
          else:
            result = false # We still want this callback to be called.
        elif res == 0:
          retFuture.complete(0)
        else:
          retFuture.complete(res)

      if pipe.readPipe == 0:
        retFuture.fail(newException(ValueError,
                                   "Read side of pipe closed or not available"))
      else:
        if not cb(AsyncFD(pipe.readPipe)):
          addRead(AsyncFD(pipe.readPipe), cb)
      return retFuture

when isMainModule:

  when not defined(windows):
    const
      SIG_DFL = cast[proc(x: cint) {.noconv,gcsafe.}](0)
      SIG_IGN = cast[proc(x: cint) {.noconv,gcsafe.}](1)
  else:
    const
      ERROR_NO_DATA = 232

  var outBuffer = "TEST STRING BUFFER"

  block test1:
    # simple read/write test
    var inBuffer = newString(64)
    var o = createPipe()
    var sc = waitFor write(o, cast[pointer](addr outBuffer[0]),
                           outBuffer.len)
    doAssert(sc == len(outBuffer))
    var rc = waitFor readInto(o, cast[pointer](addr inBuffer[0]),
                              inBuffer.len)
    inBuffer.setLen(rc)
    doAssert(inBuffer == outBuffer)
    close(o)

  block test2:
    # read from pipe closed write side
    var inBuffer = newString(64)
    var o = createPipe()
    o.closeWrite()
    var rc = waitFor readInto(o, cast[pointer](addr inBuffer[0]),
                              inBuffer.len)
    doAssert(rc == 0)

  block test3:
    # write to closed read side
    var sc: int = -1
    var o = createPipe()
    o.closeRead()
    when not defined(windows):
      posix.signal(SIGPIPE, SIG_IGN)

    try:
      sc = waitFor write(o, cast[pointer](addr outBuffer[0]),
                         outBuffer.len)
    except:
      discard
    doAssert(sc == -1)

    when not defined(windows):
      doAssert(osLastError().int32 == EPIPE)
    else:
      doAssert(osLastError().int32 == ERROR_NO_DATA)

    when not defined(windows):
      posix.signal(SIGPIPE, SIG_DFL)

  block test4:
    # bulk test of sending/receiving data
    const
      testsCount = 5000

    proc sender(o: AsyncPipe) {.async.} =
      var data = 1'i32
      for i in 1..testsCount:
        data = int32(i)
        let res = await write(o, addr data, sizeof(int32))
        doAssert(res == sizeof(int32))
      closeWrite(o)

    proc receiver(o: AsyncPipe): Future[tuple[count: int, sum: int]] {.async.} =
      var data = 0'i32
      result = (count: 0, sum: 0)
      while true:
        let res = await readInto(o, addr data, sizeof(int32))
        if res == 0:
          break
        doAssert(res == sizeof(int32))
        inc(result.sum, data)
        inc(result.count)

    var o = createPipe()
    asyncCheck sender(o)
    let res = waitFor(receiver(o))
    doAssert(res.count == testsCount)
    doAssert(res.sum == testsCount * (1 + testsCount) div 2)

