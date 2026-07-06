import std/[strtabs, osproc]

export osproc except execProcess, execCmdEx

proc execProcess*(command: string, workingDir: string = "",
                  args: openArray[string] = [], env: StringTableRef = nil,
                  options: set[ProcessOption] = {
                  poStdErrToStdOut, poUsePath, poEvalCommand}
                  ): string {.raises: [OSError, IOError],
                  tags: [ExecIOEffect, ReadIOEffect, RootEffect].} =
  {.cast(raises: [OSError, IOError]).}:
      osproc.execProcess(command, workingDir, args, env, options)

proc execCmdEx*(command: string, options: set[ProcessOption] = {
                poStdErrToStdOut, poUsePath}, env: StringTableRef = nil,
                workingDir = "", input = ""): tuple[
                output: string,
                exitCode: int] {.raises: [OSError, IOError], tags:
                [ExecIOEffect, ReadIOEffect, RootEffect], gcsafe.} =
  {.cast(raises: [OSError, IOError]).}:
    {.cast(gcsafe).}:
      osproc.execCmdEx(command, options, env, workingDir, input)
