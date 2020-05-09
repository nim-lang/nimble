
import nimblepkg/tools
import nimblepkg/version

when isMainModule:
  let current_version = getNimrodVersion()
  echo $current_version