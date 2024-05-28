# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import std/[strutils]
import common, download

type
  ForgeKind* = enum
    fgGitHub
    fgGitLab
    fgSourceHut
    fgCodeberg

  Forge* = object
    kind*: ForgeKind
    username*, repo*: string

proc expand*(alias: Forge): string {.inline.} =
  var expanded = "https://" # add an option to use http instead?

  case alias.kind
  of fgGitHub:
    expanded &= "github.com/" & alias.username & '/' & alias.repo
  of fgGitLab:
    expanded &= "gitlab.com/" & alias.username & '/' & alias.repo
  of fgSourceHut:
    expanded &= "git.sr.ht/" & alias.username & '/' & alias.repo
  of fgCodeberg:
    expanded &= "codeberg.org/" & alias.username & '/' & alias.repo

  expanded

proc isForgeAlias*(value: string): bool {.inline.} =
  let splitted = value.split(':')

  splitted.len == 2 and not isURL(value)

proc parseForgeKind*(value: string): ForgeKind {.inline.} =
  let splitted = value.split(':')
  
  case splitted[0].toLowerAscii()
  of "github", "gh": return fgGitHub
  of "gitlab", "gl": return fgGitLab
  of "sourcehut", "srht", "shart": return fgSourceHut
  of "codeberg", "cb", "cberg": return fgCodeberg
  else:
    raise nimbleError("Invalid forge alias name: " & value[0])

proc parseGenericAlias*(
  value: string, appendTilde: bool = false
): tuple[username, repo: string] {.inline.} =
  let splitted = value.split(':')

  if splitted[1].len < 1:
    raise nimbleError(
      "Invalid forge alias format; correct format:" & 
      "\n\t<alias>:<username>/<repository>\n" &
      "     ^^^^^"
    )

  let secondSplit = splitted[1].split('/')

  if secondSplit.len < 2:
    raise nimbleError(
      "Invalid forge alias format; correct format:" & 
      "\n\t<alias>:<username>/<repository>\n" &
      "                        ^^^^^^^^^^"
    )

  let
    username = block:
      var name = secondSplit[0]

      if name.len < 1:
        raise nimbleError("No username provided in forge alias: " & value)

      if appendTilde and not name.startsWith('~'):
        name = '~' & name
      
      name

    repository = secondSplit[1]

  (username: username, repo: repository)

proc newForge*(value: string): Forge {.inline.} =
  let
    kind = parseForgeKind(value)
    generic = parseGenericAlias(value, kind == fgSourceHut)
  
  Forge(
    kind: kind,
    username: generic.username,
    repo: generic.repo
  )
