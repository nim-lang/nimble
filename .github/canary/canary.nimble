# Package

version       = "0.1.0"
author        = "The Nimble contributors"
description   = "Canary: builds Nim repos, Status' and the community's, with two nimbles"
license       = "BSD"

# Dependencies

requires "nim >= 2.0.0"

# The canary's steps, as .github/workflows/canary.yml runs them. They take
# their inputs from the environment (see canary.nim).

proc canary(command: string) =
  selfExec "r --hints:off canary.nim " & command

task plan, "List the build jobs: each repo, with each nimble":
  canary "plan"

task report, "Compare each repo's builds and summarise":
  canary "report"
