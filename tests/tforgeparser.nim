# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}
import std/[unittest, os]
import nimblepkg/forge_aliases

let 
  gh = "gh:xTrayambak/testing"
  srht = "srht:~abc/xyz"
  berg = "codeberg:lorem/ipsum"
  gl = "gitlab:door/sit"

suite "forge aliases":
  test "can parse alias kinds":
    assert parseForgeKind(gh) == fgGitHub
    assert parseForgeKind(srht) == fgSourceHut
    assert parseForgeKind(berg) == fgCodeberg
    assert parseForgeKind(gl) == fgGitLab

  test "can parse generically":
    let
      pgh = parseGenericAlias(gh)
      psrht = parseGenericAlias(srht, appendTilde = true)
      pberg = parseGenericAlias(berg)
      pgl = parseGenericAlias(gl)

    assert pgh.username == "xTrayambak"
    assert psrht.username == "~abc"
    assert pberg.username == "lorem"
    assert pgl.username == "door"

    assert pgh.repo == "testing"
    assert psrht.repo == "xyz"
    assert pberg.repo == "ipsum"
    assert pgl.repo == "sit"

  test "can handle sourcehut tildes":
    let psrht = parseGenericAlias("srht:abc/xyz", appendTilde = true)
    assert psrht.username == "~abc"
