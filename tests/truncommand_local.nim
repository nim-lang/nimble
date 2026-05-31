discard """
  exitcode: 0
"""

import os, strutils, strformat
import common
from nimblepkg/common import cd

proc main() =
  let testsDir = currentSourcePath().parentDir

  block invalid_binary:
    cd testsDir / "run":
      let (output, exitCode) = execNimble(
        "--debug", "run", "blahblah")
      doAssert exitCode == QuitFailure, output
      doAssert output.contains("Binary '$1' is not defined in 'run' package." %
                                "blahblah".changeFileExt(ExeExt)), output

  block params_passed_to_executable:
    cd testsDir / "run":
      let (output, exitCode) = execNimble(
        "--debug", "run", "run", "--test", "--help", "check")
      doAssert exitCode == QuitSuccess, output
      doAssert output.contains("tests$1run$1$2 --test --help check" %
                                [$DirSep, "run".changeFileExt(ExeExt)]), output
      doAssert output.contains("""Testing `nimble run`: @["--test", "--help", "check"]"""), output

  block params_not_passed_to_single_executable:
    cd testsDir / "run":
      let (output, exitCode) = execNimble(
        "--debug", "run", "--", "--test")
      doAssert exitCode == QuitSuccess, output
      doAssert output.contains("tests$1run$1$2 --test" %
                                [$DirSep, "run".changeFileExt(ExeExt)]), output
      doAssert output.contains("""Testing `nimble run`: @["--test"]"""), output

  block params_passed_to_single_executable:
    cd testsDir / "run":
      let (output, exitCode) = execNimble(
        "--debug", "run", "--", "--test", "--help", "check")
      doAssert exitCode == QuitSuccess, output
      doAssert output.contains("tests$1run$1$2 --test --help check" %
                                [$DirSep, "run".changeFileExt(ExeExt)]), output
      doAssert output.contains("""Testing `nimble run`: @["--test", "--help", "check"]"""), output

  block executable_output_shown:
    cd testsDir / "run":
      let (output, exitCode) =
        execNimble("run", "run", "--option1", "arg1")
      doAssert exitCode == QuitSuccess, output
      doAssert output.contains("""Testing `nimble run`: @["--option1", "arg1"]"""), output

  block quotes_and_whitespace:
    cd testsDir / "run":
      let (output, exitCode) = execNimble(
        "run", "run", "\"", "\'", "\t", "arg with spaces")
      doAssert exitCode == QuitSuccess, output
      doAssert output.contains(
        """Testing `nimble run`: @["\"", "\'", "\t", "arg with spaces"]"""), output

  block nimble_options_before_executable_name:
    cd testsDir / "run":
      let (output, exitCode) = execNimble(
        "run", "--debug", "run", "--test")
      doAssert exitCode == QuitSuccess, output
      doAssert output.contains("tests$1run$1$2 --test" %
                                [$DirSep, "run".changeFileExt(ExeExt)]), output
      doAssert output.contains("""Testing `nimble run`: @["--test"]"""), output

  block nimble_options_flags_before_dashdash:
    cd testsDir / "run":
      let (output, exitCode) = execNimble(
        "run", "--debug", "--", "--test")
      doAssert exitCode == QuitSuccess, output
      doAssert output.contains("tests$1run$1$2 --test" %
                                [$DirSep, "run".changeFileExt(ExeExt)]), output
      doAssert output.contains("""Testing `nimble run`: @["--test"]"""), output

  block compilation_flags_before_run_command:
    cd testsDir / "run":
      let (output, exitCode) = execNimble(
        "-d:sayWhee", "run", "--debug", "--", "--test")
      doAssert exitCode == QuitSuccess, output
      doAssert output.contains("tests$1run$1$2 --test" %
                                [$DirSep, "run".changeFileExt(ExeExt)]), output
      doAssert output.contains("""Testing `nimble run`: @["--test"]"""), output
      doAssert output.contains("""Whee!"""), output

  block compilation_flags_before_executable_name:
    cd testsDir / "run":
      let (output, exitCode) = execNimble(
        "--debug", "run", "-d:sayWhee", "run", "--test")
      doAssert exitCode == QuitSuccess, output
      doAssert output.contains("tests$1run$1$2 --test" %
                                [$DirSep, "run".changeFileExt(ExeExt)]), output
      doAssert output.contains("""Testing `nimble run`: @["--test"]"""), output
      doAssert output.contains("""Whee!"""), output

  block compilation_flags_before_dashdash:
    cd testsDir / "run":
      let (output, exitCode) = execNimble(
        "run", "-d:sayWhee", "--debug", "--", "--test")
      doAssert exitCode == QuitSuccess, output
      doAssert output.contains("tests$1run$1$2 --test" %
                                [$DirSep, "run".changeFileExt(ExeExt)]), output
      doAssert output.contains("""Testing `nimble run`: @["--test"]"""), output
      doAssert output.contains("""Whee!"""), output

  block order_of_compilation_flags:
    cd testsDir / "run":
      let (output, exitCode) = execNimble(
        "-d:compileFlagBeforeRunCommand", "run", "-d:sayWhee",
        "--debug", "--", "--test")
      doAssert exitCode == QuitSuccess, output
      doAssert output.contains("-d:compileFlagBeforeRunCommand -d:sayWhee"), output
      doAssert output.contains("tests$1run$1$2 --test" %
                                [$DirSep, "run".changeFileExt(ExeExt)]), output
      doAssert output.contains("""Testing `nimble run`: @["--test"]"""), output
      doAssert output.contains("""Whee!"""), output

main()
