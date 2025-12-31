import std/[strtabs, osproc]

export osproc except execCmdEx

proc execCmdEx*(command: string, options: set[ProcessOption] = {
                poStdErrToStdOut, poUsePath}, env: StringTableRef = nil,
                workingDir = "", input = ""): tuple[
                output: string,
                exitCode: int] {.raises: [OSError, IOError], tags:
                [ExecIOEffect, ReadIOEffect, RootEffect], gcsafe.} =
  {.cast(raises: [OSError, IOError]).}:
    {.cast(gcsafe).}:
      osproc.execCmdEx(command, options, env, workingDir, input)