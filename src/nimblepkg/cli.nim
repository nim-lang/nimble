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
    showColor: bool ## Whether messages should be colored.
    suppressMessages: bool ## Whether Warning, Message and Success messages
                           ## should be suppressed, useful for
                           ## commands like `dump` whose output should be
                           ## machine readable.

  Priority* = enum
    DebugPriority, LowPriority, MediumPriority, HighPriority

  DisplayType* = enum
    Error, Warning, Message, Success

  ForcePrompt* = enum
    dontForcePrompt, forcePromptYes, forcePromptNo

const
  longestCategory = len("Downloading")
  foregrounds: array[Error .. Success, ForegroundColor] =
    [fgRed, fgYellow, fgCyan, fgGreen]
  styles: array[DebugPriority .. HighPriority, set[Style]] =
    [{styleDim}, {styleDim}, {}, {styleBright}]

proc newCLI(): CLI =
  result = CLI(
    level: HighPriority,
    warnings: initSet[(string, string)](),
    suppressionCount: 0,
    showColor: true,
    suppressMessages: false
  )

var globalCLI = newCLI()


proc calculateCategoryOffset(category: string): int =
  assert category.len <= longestCategory
  return longestCategory - category.len

proc displayCategory(category: string, displayType: DisplayType,
                     priority: Priority) =
  # Calculate how much the `category` must be offset to align along a center
  # line.
  let offset = calculateCategoryOffset(category)

  # Display the category.
  let text = "$1$2 " % [spaces(offset), category]
  if globalCLI.showColor:
    if priority != DebugPriority:
      setForegroundColor(stdout, foregrounds[displayType])
    writeStyled(text, styles[priority])
    resetAttributes()
  else:
    stdout.write(text)

proc displayLine(category, line: string, displayType: DisplayType,
                 priority: Priority) =
  displayCategory(category, displayType, priority)

  # Display the message.
  echo(line)

proc display*(category, msg: string, displayType = Message,
              priority = MediumPriority) =
  # Don't print any Warning, Message or Success messages when suppression of
  # warnings is enabled. That is, unless the user asked for --verbose output.
  if globalCLI.suppressMessages and displayType >= Warning and
     globalCLI.level == HighPriority:
    return

  # Multiple warnings containing the same messages should not be shown.
  let warningPair = (category, msg)
  if displayType == Warning:
    if warningPair in globalCLI.warnings:
      return
    else:
      globalCLI.warnings.incl(warningPair)

  # Suppress this message if its priority isn't high enough.
  # TODO: Per-priority suppression counts?
  if priority < globalCLI.level:
    if priority != DebugPriority:
      globalCLI.suppressionCount.inc
    return

  # Display each line in the message.
  var i = 0
  for line in msg.splitLines():
    if len(line) == 0: continue
    displayLine(if i == 0: category else: "...", line, displayType, priority)
    i.inc

proc displayDebug*(category, msg: string) =
  ## Convenience for displaying debug messages.
  display(category, msg, priority = DebugPriority)

proc displayDebug*(msg: string) =
  ## Convenience for displaying debug messages with a default category.
  displayDebug("Debug:", msg)

proc displayTip*() =
  ## Called just before Nimble exits. Shows some tips for the user, for example
  ## the amount of messages that were suppressed and how to show them.
  if globalCLI.suppressionCount > 0:
    let msg = "$1 messages have been suppressed, use --verbose to show them." %
             $globalCLI.suppressionCount
    display("Tip:", msg, Warning, HighPriority)

proc prompt*(forcePrompts: ForcePrompt, question: string): bool =
  case forcePrompts
  of forcePromptYes:
    display("Prompt:", question & " -> [forced yes]", Warning, HighPriority)
    return true
  of forcePromptNo:
    display("Prompt:", question & " -> [forced no]", Warning, HighPriority)
    return false
  of dontForcePrompt:
    display("Prompt:", question & " [y/N]", Warning, HighPriority)
    displayCategory("Answer:", Warning, HighPriority)
    let yn = stdin.readLine()
    case yn.normalize
    of "y", "yes":
      return true
    of "n", "no":
      return false
    else:
      return false

proc promptCustom*(forcePrompts: ForcePrompt, question, default: string): string =
  case forcePrompts:
  of forcePromptYes:
    display("Prompt:", question & " -> [forced " & default & "]", Warning,
      HighPriority)
    return default
  else:
    if default == "":
      display("Prompt:", question, Warning, HighPriority)
      displayCategory("Answer:", Warning, HighPriority)
      let user = stdin.readLine()
      if user.len == 0: return promptCustom(forcePrompts, question, default)
      else: return user
    else:
      display("Prompt:", question & " [" & default & "]", Warning, HighPriority)
      displayCategory("Answer:", Warning, HighPriority)
      let user = stdin.readLine()
      if user == "": return default
      else: return user

proc promptCustom*(question, default: string): string =
  return promptCustom(dontForcePrompt, question, default)

proc promptList*(forcePrompts: ForcePrompt, question: string, args: openarray[string]): string =
  case forcePrompts:
  of forcePromptYes:
    result = args[0]
    display("Prompt:", question & " -> [forced " & result & "]", Warning,
      HighPriority)
  else:
    display("Prompt:", question & " [" & join(args, "/") & "]", Warning, HighPriority)
    displayCategory("Answer:", Warning, HighPriority)
    result = stdin.readLine()
    for arg in args:
      if arg.cmpIgnoreCase(result) == 0:
        return arg
    return promptList(forcePrompts, question, args)

proc setVerbosity*(level: Priority) =
  globalCLI.level = level

proc setShowColor*(val: bool) =
  globalCLI.showColor = val

proc setSuppressMessages*(val: bool) =
  globalCLI.suppressMessages = val

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
