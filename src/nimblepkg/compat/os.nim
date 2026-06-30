import std/os

export os except moveFile

proc moveFile*(source, dest: string) {.raises: [OSError].} =
  {.cast(raises: [OSError]).}:
    os.moveFile(source, dest)
