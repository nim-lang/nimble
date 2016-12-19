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
    level: Priority
    warnings: HashSet[(string, string)]
    suppressionCount: int ## Amount of messages which were not shown.

  Priority* = enum
    LowPriority, MediumPriority, HighPriority

  DisplayType* = enum
    Error, Warning, Message, Success

const
  longestCategory = len("Downloading")
  foregrounds: array[Error .. Success, ForegroundColor] =
    [fgRed, fgYellow, fgCyan, fgGreen]
  styles: array[LowPriority .. HighPriority, set[Style]] =
    [{styleDim}, {}, {styleBright}]

proc newCLI(): CLI =
  result = CLI(
    level: HighPriority,
    warnings: initSet[(string, string)](),
    suppressionCount: 0
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

  # Suppress this message if its priority isn't high enough.
  if priority < globalCLI.level:
    globalCLI.suppressionCount.inc
    return

  # Display each line in the message.
  var i = 0
  for line in msg.splitLines():
    if len(line) == 0: continue
    displayLine(if i == 0: category else: "...", line, displayType, priority)
    i.inc

proc displayTip*() =
  ## Called just before Nimble exits. Shows some tips for the user, for example
  ## the amount of messages that were suppressed and how to show them.
  if globalCLI.suppressionCount > 0:
    let msg = "$1 messages have been suppressed, use --verbose to show them." %
             $globalCLI.suppressionCount
    display("Tip", msg, Warning, HighPriority)

proc setVerbosity*(level: Priority) =
  globalCLI.level = level

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
