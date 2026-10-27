## Canary: builds Nim repos, Status' and the community's, with two nimbles, the
## latest release ("baseline") and the one under test ("head"), and reports the
## repos that get less far with head. .github/workflows/canary.yml runs it
## through the tasks in canary.nimble; the repos are in repos.txt. Inputs come
## from the environment:
##
## nimble plan    $BASELINE (a nimble release), $NIMBLE_REF (the nimble branch,
##                tag, SHA or refs/pull/<n>/head to test; default the nightly
##                build), $ONLY (repos, comma-separated), $TESTS (`false` skips
##                `nimble test`). Writes the build `matrix` and the `head` label
##                to $GITHUB_OUTPUT, slowest repos first by the last scheduled
##                run of $GITHUB_REPOSITORY. Needs an authenticated `gh`.
## nimble report  $PLANNED (the matrix), $BASELINE, $HEAD_LABEL, and Actions'
##                $GITHUB_REPOSITORY and $GITHUB_RUN_ID, whose build jobs it
##                reads. Needs an authenticated `gh`.

import std/[algorithm, json, os, osproc, sequtils, sets, strformat, strutils, tables, times]

const
  # The build job's steps that run the recipe, in order, as canary.yml names them.
  Stages = {"Install dependencies": "install", "Test": "test"}.toOrderedTable

proc need(name: string): string =
  result = getEnv(name)
  if result.len == 0:
    quit(&"${name} is not set")

proc sh(args: openArray[string]): string =
  ## Runs a command and returns its output; quits if it fails.
  let (output, code) = execCmdEx(quoteShellCommand(args))
  if code != 0:
    quit(&"`{args.join(\" \")}` failed ({code}):\n{output}")
  output

proc short(sha: string): string = sha[0 ..< min(8, sha.len)]

proc seconds(node: JsonNode): int =
  ## How long a job or a step ran, from the jobs API's timestamps.
  const format = "yyyy-MM-dd'T'HH:mm:ss'Z'"
  let (started, completed) = (node{"started_at"}.getStr, node{"completed_at"}.getStr)
  if started.len > 0 and completed.len > 0:
    result = int(inSeconds(parse(completed, format, utc()) - parse(started, format, utc())))

# plan ------------------------------------------------------------------------

proc headNimble(): (string, string) =
  ## The `nimble-version` that setup-nimble-action installs as head, and its label.
  let nimbleRef = getEnv("NIMBLE_REF").strip
  if nimbleRef.len == 0:
    # The nightly's commit, for the label. binaries.yml republishes the nightly
    # for every push to master and every release tag, so the latest successful
    # run built it.
    let sha = sh(["gh", "api", "repos/nim-lang/nimble/actions/workflows/binaries.yml/runs" &
                  "?event=push&status=success&per_page=1",
                  "--jq", ".workflow_runs[0].head_sha"]).strip
    return ("nightly", "nightly@" & short(sha))
  # It goes into an API path.
  if not nimbleRef.allCharsInSet(Letters + Digits + {'.', '_', '/', '-'}) or ".." in nimbleRef:
    quit(&"not a git ref: {nimbleRef}")
  # Every head job builds this commit, even if the branch moves meanwhile.
  let sha = sh(["gh", "api", &"repos/nim-lang/nimble/commits/{nimbleRef}", "--jq", ".sha"]).strip
  (sha, nimbleRef & "@" & short(sha))

proc lastTimes(): Table[string, int] =
  ## How long each repo took in the last scheduled run, which builds them all:
  ## the longer of its two build jobs, in seconds. Empty if that can't be read,
  ## as the times only decide the order.
  let repository = getEnv("GITHUB_REPOSITORY", "nim-lang/nimble")
  let (run, code) = execCmdEx(quoteShellCommand(["gh", "api",
    &"repos/{repository}/actions/workflows/canary.yml/runs?event=schedule&status=completed&per_page=1",
    "--jq", ".workflow_runs[0].id // empty"]))
  if code != 0 or run.strip.len == 0:
    return
  let (jobs, jobsCode) = execCmdEx(quoteShellCommand(["gh", "api", "--paginate",
    &"repos/{repository}/actions/runs/{run.strip}/jobs?per_page=100",
    "--jq", ".jobs[] | {name, started_at, completed_at}"]))
  if jobsCode != 0:
    return
  for line in jobs.splitLines:
    if line.startsWith("{"):
      let job = parseJson(line)
      let (name, s) = (job["name"].getStr, seconds(job))
      # The build job's name in canary.yml.
      for suffix in [" (baseline)", " (head)"]:
        if name.endsWith(suffix) and s > 0:
          let repo = name[0 ..< name.len - suffix.len]
          result[repo] = max(result.getOrDefault(repo), s)

proc plan() =
  var repos: seq[(string, bool)] # the repo, and whether to run its tests
  for line in lines("repos.txt"):
    let words = line.split('#')[0].splitWhitespace
    if words.len > 0:
      repos.add (words[0], "install-only" notin words[1 .. ^1])
  let only = getEnv("ONLY").split(',').mapIt(it.strip).filterIt(it.len > 0).toHashSet
  let unknown = only - repos.mapIt(it[0]).toHashSet
  if unknown.len > 0:
    quit("not in repos.txt: " & toSeq(unknown).sorted.join(", "))
  # The build jobs start in the matrix's order, a few at a time: start the
  # slowest repos first, so they aren't the ones still building at the end.
  # Repos the last scheduled run didn't build go first too, as they may be slow.
  # The sort is stable, so ties keep the file's order.
  let times = lastTimes()
  repos.sort(proc (a, b: (string, bool)): int =
    cmp(times.getOrDefault(b[0], int.high), times.getOrDefault(a[0], int.high)))

  let baseline = need("BASELINE")
  let (head, label) = headNimble()
  let tests = getEnv("TESTS") != "false"
  var matrix = newJArray()
  for (repo, repoTests) in repos:
    if only.len == 0 or repo in only:
      # Both nimbles build the same commit.
      let sha = sh(["gh", "api", &"repos/{repo}/commits/HEAD", "--jq", ".sha"]).strip
      for (nimble, version) in [("baseline", baseline), ("head", head)]:
        matrix.add %*{"repo": repo, "sha": sha, "nimble": nimble, "version": version,
                      "tests": tests and repoTests}

  let outputs = &"matrix={matrix}\nhead={label}\n"
  stdout.write outputs
  if existsEnv("GITHUB_OUTPUT"):
    let f = open(getEnv("GITHUB_OUTPUT"), fmAppend)
    f.write outputs
    f.close()

# report ----------------------------------------------------------------------

type
  Stage = object
    name, conclusion: string # success, failure, cancelled or skipped
    seconds: int
  Build = object
    ## One build job, as the jobs API has it.
    found: bool
    url: string
    stages: seq[Stage]
    broken: string # why the job failed, if not in a stage: the canary's own failure

proc toBuild(job: JsonNode): Build =
  result = Build(found: true, url: job["html_url"].getStr)
  for step in job{"steps"}.getElems:
    let (name, conclusion) = (step["name"].getStr, step{"conclusion"}.getStr)
    if name in Stages:
      result.stages.add Stage(name: Stages[name], conclusion: conclusion, seconds: seconds(step))
    elif conclusion in ["failure", "cancelled"] and result.broken.len == 0 and
        result.stages.allIt(it.conclusion == "success"):
      result.broken = &"`{name}` failed"
  if result.broken.len > 0:
    return
  # The stages decide how far a job got, not its conclusion: GitHub has left a
  # finished job "in_progress", with no conclusion, after the run was over.
  if job{"conclusion"}.getStr == "cancelled" and
      not result.stages.anyIt(it.conclusion == "failure"):
    result.broken = "the job was cancelled"
  elif result.stages.len == 0 or result.stages.anyIt(it.conclusion.len == 0):
    result.broken = "the job didn't finish"

proc reached(b: Build): int =
  ## How many stages passed before the first one that didn't.
  for s in b.stages:
    if s.conclusion != "success":
      break
    inc result

proc passed(b: Build): bool =
  ## Whether every stage that ran passed.
  b.stages.allIt(it.conclusion in ["success", "skipped"])

proc verdict(baseline, head: Build): string =
  if not baseline.found or not head.found: "missing"
  elif baseline.broken.len > 0 or head.broken.len > 0: "error"
  elif head.reached < baseline.reached: "regression"
  elif head.reached > baseline.reached: "fixed"
  elif baseline.passed and head.passed: "ok"
  else: "red"

proc duration(seconds: int): string =
  let (m, s) = (seconds div 60, seconds mod 60)
  if m > 0: &"{m}m{s:02}s" else: &"{s}s"

proc slower(baseline, head: Build): seq[string] =
  ## Stages that took head much longer: slowing down is a regression too.
  for (b, h) in zip(baseline.stages, head.stages):
    if b.conclusion == "success" and h.conclusion == "success" and h.seconds > 2 * b.seconds + 60:
      result.add &"{h.name} took {duration(h.seconds)} on head, {duration(b.seconds)} on the baseline"

const
  Verdicts = {
    "regression": "🔴 regression",
    "error": "⚠️ canary error",
    "missing": "⚠️ no job",
    "fixed": "🟢 fixed on head",
    "red": "⚪ fails on both",
    "ok": "ok"}.toOrderedTable
  Icons = {"success": "✅", "failure": "❌", "cancelled": "⏹️"}.toTable

proc cell(b: Build): string =
  if not b.found:
    return "–"
  var parts: seq[string]
  for s in b.stages:
    if s.conclusion in Icons: # a stage that ran
      let icon = Icons[s.conclusion]
      parts.add &"{icon} {s.name} {duration(s.seconds)}"
  parts.add &"[log]({b.url})"
  parts.join("<br>")

type Row = object
  repo, sha, verdict: string
  baseline, head: Build
  notes: seq[string]

proc report() =
  let (repository, run) = (need("GITHUB_REPOSITORY"), need("GITHUB_RUN_ID"))
  var jobs = initTable[string, Build]()
  for line in sh(["gh", "api", "--paginate", &"repos/{repository}/actions/runs/{run}/jobs?per_page=100",
                  "--jq", ".jobs[] | {name, conclusion, html_url, " &
                          "steps: [.steps[] | {name, conclusion, started_at, completed_at}]}"]).splitLines:
    if line.len > 0:
      let job = parseJson(line)
      jobs[job["name"].getStr] = toBuild(job)

  var rows: seq[Row]
  for e in parseJson(need("PLANNED")):
    if e["nimble"].getStr != "baseline":
      continue
    let repo = e["repo"].getStr
    # The build job's name in canary.yml.
    var row = Row(repo: repo, sha: e["sha"].getStr,
                  baseline: jobs.getOrDefault(repo & " (baseline)"),
                  head: jobs.getOrDefault(repo & " (head)"))
    row.verdict = verdict(row.baseline, row.head)
    for (nimble, b) in [("baseline", row.baseline), ("head", row.head)]:
      if not b.found:
        row.notes.add &"no {nimble} job"
      elif b.broken.len > 0:
        row.notes.add &"{nimble}: {b.broken}"
    if row.verdict notin ["missing", "error"]:
      row.notes.add slower(row.baseline, row.head)
    rows.add row
  let order = toSeq(Verdicts.keys)
  rows.sort(proc (a, b: Row): int = cmp((order.find(a.verdict), a.repo), (order.find(b.verdict), b.repo)))

  let (baseline, head) = (need("BASELINE"), getEnv("HEAD_LABEL", "head"))
  var counts = initCountTable[string]()
  for r in rows:
    counts.inc r.verdict
  var summary: seq[string]
  for v, label in Verdicts:
    if counts[v] > 0:
      summary.add &"{counts[v]} {label}"
  var lines = @[&"## Canary: nimble {head} vs {baseline}", "",
                &"{rows.len} repos: " & summary.join(", "), "",
                &"| Repo | Commit | {baseline} | {head} | Verdict |", "|---|---|---|---|---|"]
  for r in rows:
    let commit = &"[{short(r.sha)}](https://github.com/{r.repo}/commit/{r.sha})"
    let notes = r.notes.mapIt("<br>" & it).join
    let (b, h, v) = (cell(r.baseline), cell(r.head), Verdicts[r.verdict])
    lines.add &"| {r.repo} | {commit} | {b} | {h} | {v}{notes} |"
  if counts["regression"] > 0:
    lines.add ["", "A flaky test can look like a regression: `gh run rerun " & run &
               " --failed` builds the failed jobs again and redoes this report."]

  let text = lines.join("\n") & "\n"
  echo text
  if existsEnv("GITHUB_STEP_SUMMARY"):
    let f = open(getEnv("GITHUB_STEP_SUMMARY"), fmAppend)
    f.write(text)
    f.close()
  if counts["regression"] + counts["error"] + counts["missing"] > 0:
    quit(1)

when isMainModule:
  case (if paramCount() == 1: paramStr(1) else: "")
  of "plan": plan()
  of "report": report()
  else: quit("usage: canary plan|report (see canary.nimble)")
