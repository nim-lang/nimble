# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import std/strutils
import common

type
  ForgeKind* = enum
    fgGitHub
    fgGitLab
    fgSourceHut
    fgCodeberg

  Forge* = ref object
    case kind*: ForgeKind
    of fgGitHub:
      ghUsername*, ghRepo*: string
    of fgGitLab:
      glUsername*, glRepo*: string
    of fgSourceHut:
      shUsername*, shRepo*: string
    of fgCodeberg:
    cbUsername*, cbRepo*: string

proc expand*(alias: Forge): string {.inline.} =
  var expanded = "https://" # add an option to use http instead?

  case alias.kind
  of fgGitHub:
    expanded &= "github.com/" & alias.ghUsername & '/' & alias.ghRepo
  of fgGitLab:
    expanded &= "gitlab.com/" & alias.glUsername & '/' & alias.glRepo
  of fgSourceHut:
    expanded &= "git.sr.ht/" & alias.shUsername & '/' & alias.shRepo
  of fgCodeberg:
    expanded &= "codeberg.org/" & alias.cbRepo & '/' & alias.cbRepo

  expanded

proc isForgeAlias*(value: string): bool {.inline.} =
  let splitted = value.split(':')

  splitted.len == 2

proc parseForgeKind*(value: string): ForgeKind {.inline.} =
  let splitted = value.split(':')
  
  case splitted[0].toLowerAscii()
  of "github", "gh": return fgGitHub
  of "gitlab", "gl": return fgGitLab
  of "sourcehut", "srht", "shart": return fgSourceHut
  of "codeberg", "cb", "cberg": return fgCodeberg
  else:
    raise nimbleError("Invalid forge alias name: " & value[0])

proc parseGenericAlias*(value: string, appendTilde: bool = false): tuple[username, repo: string] {.inline.} =
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

  case kind
  of fgGitHub:
    return Forge(
      kind: fgGitHub,
      ghUsername: generic.username,
      ghRepo: generic.repo
    )
  of fgGitLab:
    return Forge(
      kind: fgGitLab,
      glUsername: generic.username,
      glRepo: generic.repo
    )
  of fgSourceHut:
    return Forge(
      kind: fgSourceHut,
      shUsername: generic.username,
      shRepo: generic.repo
    )
  of fgCodeberg:
    return Forge(
      kind: fgCodeberg,
      cbUsername: generic.username,
      cbRepo: generic.repo
    )
