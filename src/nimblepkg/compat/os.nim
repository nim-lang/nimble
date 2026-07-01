import std/os

export os except copyFileWithPermissions, copyDirWithPermissions, moveFile

proc copyFileWithPermissions*(
    source, dest: string, ignorePermissionErrors = true, options = {cfSymlinkFollow}
) {.raises: [OSError].} =
  {.cast(raises: [OSError]).}:
    os.copyFileWithPermissions(source, dest, ignorePermissionErrors, options)

proc copyDirWithPermissions*(
    source, dest: string, ignorePermissionErrors = true
) {.raises: [OSError].} =
  # Pre Nim 2.2.x version for compatibility.
  {.cast(raises: [OSError]).}:
    os.copyDirWithPermissions(source, dest, ignorePermissionErrors)

proc moveFile*(source, dest: string) {.raises: [OSError].} =
  {.cast(raises: [OSError]).}:
    os.moveFile(source, dest)
