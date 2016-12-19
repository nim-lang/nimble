# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
#
# Rough rules/philosophy for the messages that Nimble displays are the following:
#   - Green is only shown when the requested operation is successful.
#   - Blue can be used to emphasise certain keywords, for example actions such
#     as "Downloading" or "Reading".
#   - Red is used when the requested operation fails with an error.
#   - Yellow is used for warnings.
#
#   - Dim for LowPriority.
#   - Bright for HighPriority.
#   - Normal for MediumPriority.

import logging, terminal, sets, strutils

type
  CLI* = ref object
    warnings: HashSet[(string, string)]

  Priority* = enum
    HighPriority, MediumPriority, LowPriority

  DisplayType* = enum
    Error, Warning, Message

const
  longestCategory = len("Downloading")
  foregrounds: array[Error .. Message, ForegroundColor] = [fgRed, fgYellow, fgCyan]
  styles: array[HighPriority .. LowPriority, set[Style]] = [{styleBright}, {}, {styleDim}]

proc newCLI(): CLI =
  result = CLI(
    warnings: initSet[(string, string)]()
  )

var globalCLI = newCLI()


proc calculateCategoryOffset(category: string): int =
  assert category.len <= longestCategory
  return longestCategory - category.len

proc displayLine(category, line: string, displayType: DisplayType,
                 priority: Priority) =
  # Calculate how much the `category` must be offset to align along a center
  # line.
  let offset = calculateCategoryOffset(category)
  # Display the category.
  setForegroundColor(stdout, foregrounds[displayType])
  writeStyled("$1$2 " % [repeatChar(offset), category], styles[priority])
  resetAttributes()

  # Display the message.
  echo(line)

proc display*(category, msg: string, displayType = Message,
              priority = MediumPriority) =
  # Multiple warnings containing the same messages should not be shown.
  let warningPair = (category, msg)
  if displayType == Warning:
    if warningPair in globalCLI.warnings:
      return
    else:
      globalCLI.warnings.incl(warningPair)

  # Display each line in the message.
  var i = 0
  for line in msg.splitLines():
    if len(line) == 0: continue
    displayLine(if i == 0: category else: "...", line, displayType, priority)
    i.inc

when isMainModule:
  display("Reading", "config file at /Users/dom/.config/nimble/nimble.ini",
          priority = LowPriority)

  display("Reading", "official package list",
        priority = LowPriority)

  display("Downloading", "daemonize v0.0.2 using Git",
      priority = HighPriority)

  display("Warning", "dashes in package names will be deprecated", Warning,
      priority = HighPriority)

  display("Error", """Unable to read package info for /Users/dom/.nimble/pkgs/nimble-0.7.11
Reading as ini file failed with:
  Invalid section: .
Evaluating as NimScript file failed with:
  Users/dom/.nimble/pkgs/nimble-0.7.11/nimble.nimble(3, 23) Error: cannot open 'src/nimblepkg/common'.
""", Error, HighPriority)
