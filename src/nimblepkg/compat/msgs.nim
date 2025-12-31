import compiler/[lineinfos, msgs, options, pathutils]

export msgs except fileInfoIdx, liMessage, localError

# TODO https://github.com/nim-lang/Nim/pull/25399
proc fileInfoIdx*(conf: ConfigRef; filename: AbsoluteFile; isKnownFile: var bool): FileIndex =
  {.cast(raises: [CatchableError]).}:
    {.cast(gcsafe).}:
      msgs.fileInfoIdx(conf, filename, isKnownFile)

proc fileInfoIdx*(conf: ConfigRef; filename: AbsoluteFile): FileIndex =
  var dummy: bool = false
  result = fileInfoIdx(conf, filename, dummy)

proc liMessage*(conf: ConfigRef; info: TLineInfo, msg: TMsgKind, arg: string,
               eh: TErrorHandling, info2: InstantiationInfo, isRaw = false,
               ignoreError = false) {.gcsafe, noinline, raises: [CatchableError].} =
  {.cast(raises: [CatchableError]).}:
    {.cast(gcsafe).}:
      when compiles(msgs.liMessage(conf, info, msg, arg, eh, info2, isRaw, ignoreError)):
        msgs.liMessage(conf, info, msg, arg, eh, info2, isRaw, ignoreError)
      else:
        msgs.liMessage(conf, info, msg, arg, eh, info2, isRaw)

proc liMessage2*(conf: ConfigRef; info: TLineInfo, msg: TMsgKind, arg: string,
               eh: TErrorHandling, info2: InstantiationInfo, isRaw = false,
               ignoreError = false) {.gcsafe, noinline, raises: [CatchableError].} =
  {.cast(raises: [CatchableError]).}:
    liMessage(conf, info, msg, arg, eh, info2, isRaw, ignoreError)

template localError*(conf: ConfigRef; info: TLineInfo, msg: TMsgKind, arg = "") =
  liMessage2(conf, info, msg, arg, doNothing, instLoc())

template localError*(conf: ConfigRef; info: TLineInfo, arg: string) =
  liMessage2(conf, info, errGenerated, arg, doNothing, instLoc())
