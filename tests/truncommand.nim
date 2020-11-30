# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strutils
import testscommon
from nimblepkg/common import cd

suite "nimble run":
  test "Invalid binary":
    cd "run":
      let (output, exitCode) = execNimble(
        "--debug", # Flag to enable debug verbosity in Nimble
        "run", # Run command invokation
        "blahblah", # The command to run
      )
      check exitCode == QuitFailure
      check output.contains("Binary '$1' is not defined in 'run' package." %
                            "blahblah".changeFileExt(ExeExt))

  test "Parameters passed to executable":
    cd "run":
      let (output, exitCode) = execNimble(
        "--debug", # Flag to enable debug verbosity in Nimble
        "run", # Run command invokation
        "run", # The command to run
        "--test", # First argument passed to the executed command
        "check" # Second argument passed to the executed command.
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test check" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      check output.contains("""Testing `nimble run`: @["--test", "check"]""")

  test "Parameters not passed to single executable":
    cd "run":
      let (output, exitCode) = execNimble(
        "--debug", # Flag to enable debug verbosity in Nimble
        "run", # Run command invocation
        "--", # Separator for arguments
        "--test" # First argument passed to the executed command
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      check output.contains("""Testing `nimble run`: @["--test"]""")

  test "Parameters passed to single executable":
    cd "run":
      let (output, exitCode) = execNimble(
        "--debug", # Flag to enable debug verbosity in Nimble
        "run", # Run command invokation
        "--", # Flag to set run file to "" before next argument
        "--test", # First argument passed to the executed command
        "check" # Second argument passed to the executed command.
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test check" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      check output.contains("""Testing `nimble run`: @["--test", "check"]""")

  test "Executable output is shown even when not debugging":
    cd "run":
      let (output, exitCode) =
        execNimble("run", "run", "--option1", "arg1")
      check exitCode == QuitSuccess
      check output.contains("""Testing `nimble run`: @["--option1", "arg1"]""")

  test "Quotes and whitespace are well handled":
    cd "run":
      let (output, exitCode) = execNimble(
        "run", "run", "\"", "\'", "\t", "arg with spaces")
      check exitCode == QuitSuccess
      check output.contains(
        """Testing `nimble run`: @["\"", "\'", "\t", "arg with spaces"]""")

  test "Nimble options before executable name":
    cd "run":
      let (output, exitCode) = execNimble(
        "run", # Run command invokation
        "--debug", # Flag to enable debug verbosity in Nimble
        "run", # The executable to run
        "--test" # First argument passed to the executed command
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      check output.contains("""Testing `nimble run`: @["--test"]""")

  test "Nimble options flags before --":
    cd "run":
      let (output, exitCode) = execNimble(
        "run", # Run command invokation
        "--debug", # Flag to enable debug verbosity in Nimble
        "--", # Separator for arguments
        "--test" # First argument passed to the executed command
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      check output.contains("""Testing `nimble run`: @["--test"]""")

  test "Compilation flags before run command":
    cd "run":
      let (output, exitCode) = execNimble(
        "-d:sayWhee", # Compile flag to define a conditional symbol
        "run", # Run command invokation
        "--debug", # Flag to enable debug verbosity in Nimble
        "--", # Separator for arguments
        "--test" # First argument passed to the executed command
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      check output.contains("""Testing `nimble run`: @["--test"]""")
      check output.contains("""Whee!""")

  test "Compilation flags before executable name":
    cd "run":
      let (output, exitCode) = execNimble(
        "--debug", # Flag to enable debug verbosity in Nimble
        "run", # Run command invokation
        "-d:sayWhee", # Compile flag to define a conditional symbol
        "run", # The executable to run
        "--test" # First argument passed to the executed command
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      check output.contains("""Testing `nimble run`: @["--test"]""")
      check output.contains("""Whee!""")

  test "Compilation flags before --":
    cd "run":
      let (output, exitCode) = execNimble(
        "run", # Run command invokation
        "-d:sayWhee", # Compile flag to define a conditional symbol
        "--debug", # Flag to enable debug verbosity in Nimble
        "--", # Separator for arguments
        "--test" # First argument passed to the executed command
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      check output.contains("""Testing `nimble run`: @["--test"]""")
      check output.contains("""Whee!""")

  test "Order of compilation flags before and after run command":
    cd "run":
      let (output, exitCode) = execNimble(
        "-d:compileFlagBeforeRunCommand", # Compile flag to define a conditional symbol
        "run", # Run command invokation
        "-d:sayWhee", # Compile flag to define a conditional symbol
        "--debug", # Flag to enable debug verbosity in Nimble
        "--", # Separator for arguments
        "--test" # First argument passed to the executed command
      )
      check exitCode == QuitSuccess
      check output.contains("-d:compileFlagBeforeRunCommand -d:sayWhee")
      check output.contains("tests$1run$1$2 --test" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      check output.contains("""Testing `nimble run`: @["--test"]""")
      check output.contains("""Whee!""")
