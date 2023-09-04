## * Convenience functions to convert Unix like file permissions to and from ``set[FilePermission]``.
import os


func toFilePermissions*(perm: Natural): set[FilePermission] =
  ## Convenience func to convert Unix like file permission to ``set[FilePermission]``.
  ##
  ## See also:
  ## * `getFilePermissions <#getFilePermissions,string>`_
  ## * `setFilePermissions <#setFilePermissions,string,set[FilePermission]>`_
  runnableExamples:
    import os
    doAssert toFilePermissions(0o700) == {fpUserExec, fpUserRead, fpUserWrite}
    doAssert toFilePermissions(0o070) == {fpGroupExec, fpGroupRead, fpGroupWrite}
    doAssert toFilePermissions(0o007) == {fpOthersExec, fpOthersRead, fpOthersWrite}
    doAssert toFilePermissions(0o644) == {fpUserWrite, fpUserRead, fpGroupRead, fpOthersRead}
    doAssert toFilePermissions(0o777) == {fpUserExec, fpUserWrite, fpUserRead, fpGroupExec, fpGroupWrite, fpGroupRead, fpOthersExec, fpOthersWrite, fpOthersRead}
    doAssert toFilePermissions(0o000) == {}
  var perm = uint(perm)
  for permBase in [fpOthersExec, fpGroupExec, fpUserExec]:
    if (perm and 1) != 0: result.incl permBase         # Exec
    if (perm and 2) != 0: result.incl permBase.succ()  # Read
    if (perm and 4) != 0: result.incl permBase.succ(2) # Write
    perm = perm shr 3  # Shift to next permission group


func fromFilePermissions*(perm: set[FilePermission]): uint =
  ## Convenience func to convert ``set[FilePermission]`` to Unix like file permission.
  ##
  ## See also:
  ## * `getFilePermissions <#getFilePermissions,string>`_
  ## * `setFilePermissions <#setFilePermissions,string,set[FilePermission]>`_
  runnableExamples:
    import os
    doAssert fromFilePermissions({fpUserExec, fpUserRead, fpUserWrite}) == 0o700
    doAssert fromFilePermissions({fpGroupExec, fpGroupRead, fpGroupWrite}) == 0o070
    doAssert fromFilePermissions({fpOthersExec, fpOthersRead, fpOthersWrite}) == 0o007
    doAssert fromFilePermissions({fpUserWrite, fpUserRead, fpGroupRead, fpOthersRead}) == 0o644
    doAssert fromFilePermissions({fpUserExec, fpUserWrite, fpUserRead, fpGroupExec, fpGroupWrite, fpGroupRead, fpOthersExec, fpOthersWrite, fpOthersRead}) == 0o777
    doAssert fromFilePermissions({}) == 0o000
    static: doAssert 0o777.toFilePermissions.fromFilePermissions == 0o777
  if fpUserExec in perm:    inc result, 0o100  # User
  if fpUserWrite in perm:   inc result, 0o200
  if fpUserRead in perm:    inc result, 0o400
  if fpGroupExec in perm:   inc result, 0o010  # Group
  if fpGroupWrite in perm:  inc result, 0o020
  if fpGroupRead in perm:   inc result, 0o040
  if fpOthersExec in perm:  inc result, 0o001  # Others
  if fpOthersWrite in perm: inc result, 0o002
  if fpOthersRead in perm:  inc result, 0o004


proc chmod*(path: string; permissions: Natural) {.inline.} =
  ## Convenience proc for `os.setFilePermissions("file.ext", filepermissions.toFilePermissions(0o666))`
  ## to change file permissions using Unix like octal file permission.
  ##
  ## See also:
  ## * `setFilePermissions <#setFilePermissions,string,set[FilePermission]>`_
  setFilePermissions(path, toFilePermissions(permissions))
