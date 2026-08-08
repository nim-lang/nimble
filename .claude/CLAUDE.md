# Nimble Project Knowledge Base

This file stores accumulated knowledge about the Nimble project learned across conversations.

**Directive**: After each conversation, annotate all new things learned from the code in this file.

---

## IMPORTANT: Git Commit Policy

**NEVER commit changes without explicit permission from the user.** Always wait for the user to tell you to commit. Do not proactively create commits even if changes are complete.

---

## Project Overview

**Nimble** is the official package manager for the Nim programming language.

- **Repository**: nimble-2 (local development copy)
- **Language**: Nim
- **Purpose**: Package dependency management, installation, publishing, and task running

---

## Project Structure

### Core Source Files (`src/nimblepkg/`)

- `nimblesat.nim` - SAT-based dependency resolver
- `packageinfo.nim` - Package metadata handling
- `download.nim` - Package downloading logic
- `install.nim` - Installation logic
- `lockfile.nim` - Lock file management
- `vnext.nim` - New vnext mode implementation (declarative parser, improved dependency resolution)
- `tools.nim` - Utility functions including `doCmd`, `extractBin`, command execution
- `nimble.nim` - Main entry point (in `src/`)

### Tests (`tests/`)

- Contains many test scenarios for various features
- Each test typically has its own directory with a `.nimble` file

---

## Recent Work (from git history)

- **46de72f7**: Track git errors during package discovery and show them when dependencies are missing
- **5f4d8dc9**: Nim special version can be used in requires
- **e5bd4abf**: Fixes issue where root package was being added to the lock file
- **1761a135**: Fix case-sensitivity bug in topologicalSort

---

## Key Concepts Learned

### vnext Mode (Only Mode)
- Legacy mode has been removed. vnext with declarative parser is the only code path.
- The `--legacy`, `--solver`, and `isLegacy` have been deleted. `useDeclarativeParser` is always true.
- `options.satResult` stores SAT solver results including:
  - `satResult.pkgList` - Available packages for resolution
  - `satResult.solvedPkgs` - Solved packages from SAT solver
  - `satResult.pkgs` - Full PackageInfo for solved packages
  - `satResult.nimResolved` - The resolved nim version/package

### Lock File Generation (`nimble lock`)
- Lock file generation happens in `proc lock` in `src/nimble.nim` (line ~2033)
- In vnext mode, it iterates over `options.satResult.solvedPkgs` to build the lock file
- The `shouldAddNim` variable controls whether nim is included in the lock file

### `--useSystemNim` Flag
- When set, nimble uses the system's nim instead of resolving/installing nim
- Located in `options.useSystemNim`
- Key behavior: When `--useSystemNim` is set during `nimble lock`, nim should NOT be included in the lock file, but all other dependencies should still be resolved

### Dependency Resolution Flow
1. `runVNext` is called for supported actions (see `vNextSupportedActions`)
2. `solvePkgs` initializes the package list and calls `resolveAndConfigureNim`
3. `resolveAndConfigureNim` (vnext.nim:533) resolves nim and runs SAT solver
4. `solvePackagesWithSystemNimFallback` actually runs the SAT solver
5. Results are stored in `options.satResult.solvedPkgs` and `options.satResult.pkgs`

### Build Process
- `buildFromDir` (vnext.nim) handles building packages
- `getPathsAllPkgs` (vnext.nim) collects paths for `--path` flags
- Nim should be excluded from paths - it's the compiler, not a library dependency
- `doCmd` (tools.nim:19) executes shell commands and checks exit codes

---

## Code Patterns & Conventions

- Error raising: Use `raise newNimbleError[NimbleError]("message")` or `raise nimbleError("message")`
- Package name checks: `pkgName.isNim` checks if a package name refers to nim
- Optional handling: Use `Option[T]` with `.isSome`, `.isNone`, `.get`
- Shell quoting: Use `quoteShell` for command arguments (uses single quotes on macOS, double quotes on Windows)

---

## Common Issues & Solutions

### Issue: `nimble develop --withDependencies` generates empty nimble.paths
**Root cause**: `actionDevelop` was not in `vNextSupportedActions`, so `runVNext` never ran for develop. Without `runVNext`, `satResult.pkgs` stayed empty and `updatePathsFile` (which uses `getPathsAllPkgs` → `satResult.pkgs`) generated an empty nimble.paths.

**Chicken-and-egg problem**: `runVNext` runs BEFORE `develop()`, but vendor packages are created BY `develop()`. So the SAT solver can't resolve packages that don't exist yet.

**Fix** (4 parts):
1. Added `actionDevelop` to `vNextSupportedActions` (options.nim)
2. Added early return in `runVNext` for `actionDevelop` - just init `satResult`, skip solving
3. After `runVNext` returns early for develop, call `opt.setNimBin()` to set nim from PATH
4. In `develop()`, after vendor is created and `withDependencies` is true: re-init `satResult`, re-parse root package, call `solvePkgs`, resolve `pkgsToInstall` from develop packages, then call `setup()` to generate nimble.paths

**Additional fixes**:
- Skip nim in `getPathsAllPkgs` (vnext.nim) - nim is the compiler, not a library dependency
- After `solvePkgs`, resolve `pkgsToInstall` from develop packages: the SAT solver may flag vendor packages for download when cached versions shadow them in `processRequirements`'s `hasVersion` check

**Key insight**: The `hasVersion` check in `processRequirements` (nimblesat.nim:1293) skips adding preferred (develop) packages when the cache already has ANY version. This causes the SAT solver to pick cached versions for some packages (like regex, unicodedb). Those then don't match in the pkgList → end up in `pkgsToInstall` instead of `satResult.pkgs`.

### Issue: `--useSystemNim` with `nimble lock` only included nim in lock file
**Root cause**: In `resolveAndConfigureNim`, when `useSystemNim` was true, it returned early without:
1. Setting `options.satResult.pkgList`
2. Running the SAT solver to populate `solvedPkgs`

**Fix**: 
1. Changed `shouldAddNim` in lock proc (nimble.nim:2102) to `not options.useSystemNim and rootReqNim` - only add nim to lock file when root explicitly requires nim AND not using system nim.
2. Modified `resolveAndConfigureNim` (vnext.nim:555-571) to handle `useSystemNim` properly:
   - **With lock file**: Return early, let `solveLockFileDeps` handle resolution from lock file
   - **Without lock file**: Run the SAT solver with system nim as the resolved nim

**Key insight**: When installing a package that has its own lock file (e.g., `nimlangserver`), running the SAT solver early ignores the lock file and causes duplicate package versions. The lock file handling via `solveLockFileDeps` must be respected.

### Issue: `nimble build` failed with linker errors (duplicate symbols from compiler/options.nim)
**Root cause**: `getPathsAllPkgs` was including the nim installation directory in `--path` flags, which caused the nim compiler's internal modules (`compiler/options.nim`, etc.) to be found and compiled, creating symbol conflicts.

**Fix**: Modified `getPathsAllPkgs` (vnext.nim:775) to skip nim packages when collecting paths.

### Issue: `nimble build` failed with "not in PATH" error for single-quoted paths
**Root cause**: `extractBin` in tools.nim only handled double-quoted paths (`"`), but `quoteShell` on macOS uses single quotes (`'`). When the nim binary path contained special characters (like `#` in `nim-#devel`), `findExe` couldn't find the quoted path.

**Fix**: Modified `extractBin` (tools.nim:13) to also handle single-quoted paths.

### Issue: Declarative parser warnings showing for packages not in solution
**Root cause**: Warnings for babel packages and declarative parser errors were being displayed immediately with `HighPriority`, regardless of whether the package was in the solution.

**Fix**:
1. Added `declarativeParserErrors: seq[string]` field to `PackageInfo` (packageinfotypes.nim:83)
2. In `declarativeparser.nim`, errors are attached directly to the package
3. In verbose mode (`options.verbosity <= LowPriority`): Display warnings immediately
4. After solution is known (in `solvePkgs`): Iterate `satResult.pkgs` and display each package's errors
5. Removed `declarativeParserErrorLines` table from `SATResult` - no longer needed

**Verbosity levels**: `--verbose` sets `LowPriority`, `--debug` sets `DebugPriority`. Check with `options.verbosity <= LowPriority` to include both.

### Issue: Special version requirements (`#head`) were satisfied by tagged versions in SAT solver
**Problem**: When SAT solver built constraints for `dep#head`, it would include tagged versions as valid solutions because `withinRange` was used, which allows normal versions to satisfy special requirements (for post-download validation).

**Why `withinRange` is lenient**: When you download `dep#head`, the package's nimble file contains a normal version like `0.2.6`. Post-download validation uses `withinRange` to check if `0.2.6` satisfies `#head` - it returns `true` because the branch was successfully downloaded.

**Fix**: Created a new `satisfiesConstraint` function (version.nim) for SAT solver use:
```nim
proc satisfiesConstraint*(ver: Version, ran: VersionRange): bool =
  # For special requirements, only exact special version matches
  case ran.kind
  of verSpecial:
    return ver.isSpecial and ver == ran.spe  # Strict!
  else:
    return withinRange(ver, ran)  # Normal matching
```

**Changes made**:
1. Added `satisfiesConstraint` function in version.nim - strict matching for SAT constraints
2. Updated `toFormular` in nimblesat.nim to use `satisfiesConstraint` instead of `withinRange`

**Note**: No special handling needed for root vs transitive requirements - the SAT constraint logic handles everything correctly.

### Issue: Windows path length exceeded during `nimble install` (copying tests directory)
**Root cause**: `iterInstallFilesSimple` and `checkInstallDir` in packageinfo.nim were copying the entire project including `tests/` directory. When packages have deep `.git` paths (like bearssl with submodules), the combined path exceeds Windows' 260 char MAX_PATH limit.

**Fix**: Skip `tests` directory during installation (like `nimcache` is skipped):
```nim
# In checkInstallDir (line ~452):
if thisDir == "nimcache" or thisDir == "tests": result = true

# In iterInstallFilesSimple (line ~492):
if dirName == "nimcache" or dirName == "tests":
  skipDir = true
```

**Note**: The `.git` directory allowance for vnext mode (added Nov 2025 for before-install hooks) combined with test artifacts created this issue.

### Issue: Windows cross-drive symlink stubs failing
**Root cause**: On Windows CI, pkgcache can be on C: drive while project (nimbledeps/bin) is on D: drive. `relativePath()` between different drives returns an absolute path, breaking the `%~dp0\` mechanism in batch stubs.

**Fix**: In `packageinstaller.nim`, check if path is absolute and use absolute path directly:
```nim
if symlinkDestRel.isAbsolute:
  # Cross-drive: use absolute path directly
  contents.add "\"" & symlinkDest & "\" %*\n"
else:
  # Same drive: use relative path with %~dp0
  contents.add "\"%~dp0\\" & symlinkDestRel & "\" %*\n"
```

### Issue: `develop --withDependencies` missing packages (regex, unicodedb) in vnext mode
**Root cause**: `getPkgInfoFromDirWithDeclarativeParser` (declarativeparser.nim:737) never set `isLink` on the returned PackageInfo. It calls `initPackageInfo()` which defaults `isLink` to `false`. Compare with `readPackageInfo` (packageparser.nim:299) which correctly sets `pkgInfo.isLink = not nf.startsWith(options.getPkgsDir)`.

Since develop packages are loaded via the declarative parser during `satNimSelection` pass (validatePackage in developfile.nim:176), ALL develop packages had `isLink=false`. This means the SAT solver couldn't distinguish develop (vendor/) packages from installed packages, causing incorrect version selection and missing packages.

**Fix**: Added `result.isLink = not nimbleFile.startsWith(options.getPkgsDir)` after `initPackageInfo()` in `getPkgInfoFromDirWithDeclarativeParser`.

**Additional change**: Added re-solve logic in `develop()` (nimble.nim) to run `solvePkgs` + `setup` after vendor packages are created, since `actionDevelop` is not in `vNextSupportedActions` (runVNext doesn't run for develop).

**Key insight**: `actionDevelop` is NOT in `vNextSupportedActions`, so `runVNext` never runs for develop commands. The re-solve must be done explicitly in the `develop()` function.

### Issue: rebuild with a commit-pinned dependency fails with `cannot open file: <mod>` (issue #1752)
**Symptom**: A project `requires "https://.../pkg#<commit>"`. First `nimble build` succeeds; the second fails with `Error: cannot open file: <module>`. Clearing the cached `pkgs2/pkg-*` dir gives one more success, then it repeats. General to ANY commit/special-pinned dep whose installed nimble file sets `srcDir` (uirelays#688dd44 in the report just makes it obvious — its files are at the package root while `srcDir="src"`).

**Root cause**: The two package-info readers set `PackageInfo.source` inconsistently. Both only had `if not nf.startsWith(getPkgsDir): source = psDevelop` with **no `else`**, so a package read straight from `pkgs2` kept the default `psLocal` (not `psInstalled`). `getRealDir` (packageinfo.nim:385) appends `srcDir` when `not isInstalled or isLink`; with `psLocal`, `isInstalled=false` → the `--path` points at a non-existent `pkgs2/pkg-*/src` subdir.

Why only special-pinned deps: the SAT solver's strict `satisfiesConstraint` won't match a cached NORMAL version (e.g. `0.8.0`) against a special constraint (`#<commit>`), so the dep is re-routed through the install path. There `packageExists` (install.nim:111) reads the cached dir via `getPkgInfo` (default `pikFull` → `getPkgInfoVm` → `readPackageInfo`) and returns it with `psLocal`. Normal-version deps resolve from the `getInstalledPkgsMin` pkgList (already `psInstalled`) and never hit this path — which is why only special-pinned deps break.

**Fix**: add the missing `else: source = psInstalled` branch in BOTH readers — `readPackageInfo` (packageparser.nim, the load-bearing one for this bug) and `getPkgInfoFromDirWithDeclarativeParser` (declarativeparser.nim, parallel reader). Mirrors `getInstalledPkgs` (packageparser.nim:434) and `getInstalledPackageMin` (packageinfo.nim:302) which already set `psInstalled` explicitly.

**Test**: `tests/tbuildinstall.nim` "rebuilding with a commit-pinned dependency finds its sources (#1752)" — fixture `tests/buildInstall/commitpinnedbuild` requires `uirelays#688dd44`, builds twice, asserts both succeed. RED against reverted source reproduces `cannot open file: uirelays` on the 2nd build.

**Note**: `getPkgInfo(dir, ..., level=pikFull)` (the default) goes to the VM parser, NOT the declarative parser — only `pikRequires` uses `getPkgInfoFromDirWithDeclarativeParser`. Don't assume a `getPkgInfo` call routes through the declarative reader.

### Issue: `nimble install` doesn't copy symlinked files into buildtemp (issue #1730)
**Symptom**: `nimble build` works but `nimble install` fails. The essence is **symlinked files in general** — most commonly a source module a binary imports (a "dep"), or a shared `binary.nim.cfg`. `build` compiles in place (symlinks resolve); `install` builds in a `buildtemp` copy where the symlink was missing → `Error: cannot open file: <module>` (or a missing-config error).

**Root cause**: The buildtemp copy loop in `installFromDirDownloadInfo` (install.nim ~239) used `walkDirRec(downloadDir, yieldFilter = {pcFile, pcDir})`. Symlinks are `pcLinkToFile`/`pcLinkToDir`, which were NOT in the yieldFilter, so symlinked files were silently skipped and never copied into buildtemp.

**Fix**: Added `pcLinkToFile, pcLinkToDir` to the `yieldFilter` and a `path.symlinkExists` branch that recreates the symlink in buildtemp via `createSymlink(expandSymlink(path), destPath)`, falling back to copying dereferenced content on `OSError` (e.g. unprivileged Windows). Must check `symlinkExists` BEFORE `dirExists` (the latter follows symlinks-to-dirs).

**Real scenario (confirmed with the maintainer)**: a ROOT package depends on a binary package; installing the root builds that dependency in buildtemp, where its symlinked files were dropped. `nimble build` on a root with no `bin` of its own says "Nothing to build" (doesn't build the dep's binary), which is why build doesn't hit it. The dep is installed via the non-root branch of `installEntry` (install.nim:~490) → same `installFromDirDownloadInfo` buildtemp copy.

**Test**: `tests/tbuildinstall.nim` "installing a root builds a binary dependency with a symlinked file (#1730)". The binary dependency is a **permanent public repo** `https://github.com/jmgomez/symlink_dep` (authored by jmgomez) — a binary package (`bin = @["symlink_dep"]`) whose binary `import`s `shared`, resolved through a committed git symlink `src/shared.nim -> realmod/shared.nim`. The root fixture `tests/buildInstall/symlinkroot/symlinkroot.nimble` just does `requires "https://github.com/jmgomez/symlink_dep"`. The test `cd`s into symlinkroot and runs `nimble install`; the dep is fetched from GitHub and built in buildtemp. Skips on Windows (git doesn't preserve symlinks there by default). This follows the existing idiom of URL/`packagebin*` test deps — no runtime git/file:///packages.json.

**Why not file:// for the test**: I explored making a `file://` dep reproduce this and it can't — `file://` deps resolve in place (treated as develop, `isLink=true`), are never built in buildtemp, and `nimble install` of a root with a `file://` require is rejected when the root is copied to pkgs2 (`validateFileUrlRequires`, declarativeparser.nim). Only a real fetched dependency (URL/package-list, git) gets installed+built in buildtemp. (A separate idea — making `file://` deps with `bin` also build in buildtemp — was considered and dropped.)

**RED/GREEN reminder**: the harness recompiles `src/nimble` from source on startup (testscommon.nim:217), so validate by reverting the SOURCE (`git show origin/master:src/nimblepkg/install.nim`), not by swapping the binary.

**CRITICAL test-harness gotcha (cost me a long debug)**: `tests/testscommon.nim` (~line 217, top-level `block:`) does `nim c src/nimble.nim` on **every** test-binary startup — it always recompiles nimble from the CURRENT source. So you CANNOT validate RED/GREEN by swapping the `src/nimble` binary (it gets overwritten). To get a real RED, revert the SOURCE (`git show origin/master:src/nimblepkg/install.nim > ...`), run the test, then restore the fix. Also note `getBuildTempDir` (options.nim) uses the GLOBAL `config.nimbleDir` (~/.nimble/buildtemp), NOT `--nimbleDir`, and local installs get the empty-string checksum `da39a3ee...` in the buildtemp dir name — so buildtemp is shared global state across runs.

**Note**: The pre-existing "special versions do not have # in directory names" test fails locally because the installed `nim-2.x` package bundles Nim's own test fixtures containing a `pkgC-#aa11` dir. Environmental, unrelated to install logic.

---

## Version Matching

See `nimble-guide/docs/version.md` for full documentation.

### Two Matching Functions
1. **`withinRange`** (lenient): Used for post-download validation. Allows normal versions to satisfy special requirements.
2. **`satisfiesConstraint`** (strict): Used by SAT solver. Special requirements require exact special version match.

### Key Rules (satisfiesConstraint - SAT solver)
1. **Special version requirements** (`#head`): Require **exact match**. Normal tagged versions do NOT satisfy.
2. **Normal version requirements** (`>= 1.0.0`): Can be satisfied by both tagged versions and special versions with matching semantic version.

### Key Rules (withinRange - validation)
1. **Special version requirements** (`#head`): Normal versions satisfy it (the branch was downloaded, its nimble file version is accepted).
2. **Normal version requirements**: Same as `satisfiesConstraint`.

---

## Development Notes

- Main branch: `master`
- Test project for lock file testing: `/Volumes/Store/Dropbox/Projects/Temp/issue_nico`

### Testing in Linux / Clean Environment
Use the Docker debug setup to reproduce issues in Linux:
```bash
# Build and run the test container
docker build -f tests/Dockerfile.debug -t nimble-debug . && docker run --rm nimble-debug

# Modify the CMD in tests/Dockerfile.debug to run specific tests:
# CMD ["./src/nimble", "test", "issues::issue #1251..."]
# CMD ["./src/nimble", "test", "lock file::"]
```

### Testing on Windows
Windows VM available for testing Windows-specific issues:

**Connection:**
```bash
sshpass -p '7900gt' ssh -o StrictHostKeyChecking=no jmgomez@192.168.2.100 "command here"
```

**Paths on Windows VM:**
- Nim 2.2.0: `C:\nim\nim-2.2.0\bin\nim.exe`
- Nimble repo: `C:\nim\nimble` (clone with `git clone -b <branch> https://github.com/jmgomez/nimble.git`)
- NimbleDir for testing: `C:\nimbleDir`
- Other Nim sources: `C:\NimSources\` (contains Nim, nimble, langserver, atlas, etc.)

**Building on Windows:**
- No gcc installed by default - use clang: `nim c --cc:clang -d:release src/nimble.nim`
- Or add `--cc:clang` to `C:\nim\nim-2.2.0\config\nim.cfg` for all compilations

**Common Windows-specific issues:**
- Path length limit: Windows MAX_PATH is 260 chars. Deep `.git` directories can exceed this.
- Cross-drive paths: `relativePath()` returns absolute path when paths are on different drives (e.g., C: vs D:)
- File permissions: Different from Unix, use `setFilePermissions` carefully

## Token Hygiene

Most token spend in a long session is re-sending context you already have — every
request replays the whole conversation. Cost is `context_size × request_count`.
Keep both small.

**Compact at ~60% of the context window.** Don't wait for auto-compact at 90%+; by
then you've paid the inflated price on hundreds of requests. Write durable state
out first (TODO comment, plan file, commit), then compact. At a natural task
boundary, prefer a fresh session over compaction.

**Never read a log whole.** Build output, test output, CI logs and background-task
`.output` files are ~99% noise.
- Claude Code: delegate to the `log-triage` subagent.
- Codex / OpenCode: `wc -l`, then `grep -nE 'error|Error|FAIL|fatal' "$LOG" | head -40`
  and `tail -40 "$LOG"`.

**Never poll from the main context.** A status check every 30s on a 20-minute build
is 40 full-context requests to learn one bit.
- Claude Code: `Monitor` with an until-condition, `run_in_background: true`, or the
  `task-watcher` subagent. Never write an `echo idle` loop.
- Codex / OpenCode: block inside a *single* shell call —
  `while ! test -f "$SENTINEL"; do sleep 30; done`.

**Cap subagent fan-out.** Opus 5 delegates far more readily than Opus 4.8 — measured
here, subagents were 51% of total spend, ~25 running concurrently at 200–350k context
each. Every subagent re-establishes context, re-explores, reports back, and then the
coordinator re-reads the report. Delegate only when the payoff clearly exceeds that
overhead: wide multi-file investigations and genuinely independent parallel tracks.
Never delegate work you could finish in a handful of tool calls, and never delegate
verification — that belongs in the main loop. Prefer one subagent over several; brief
it precisely the first time; don't re-derive its findings when it reports back. Keep
concurrent spawns in the single digits unless explicitly asked for more.

**Never read an image twice.** A screenshot costs ~1.5–3k tokens and is never
summarized away. Downscale first (`sips -Z 1200 in.png --out small.png`), delegate
to the `visual-evidence` subagent where available, read once, and refer to your own
written notes afterwards. For browser work prefer DOM text (`browser_snapshot`,
`read_page`) over pixels.

**Cheap habits:** grep before read; never re-read a file already in context; cap
output with `head -50` / `--quiet`; `git log --oneline -20`; delegate broad
multi-file searches to an `Explore`/`general-purpose` subagent; batch independent
tool calls into one message.

Full guidance: `context-budget` and `visual-evidence` skills (available in Claude
Code via `Skill`, in Codex via `~/.agents/skills`, in OpenCode via `skill({name})`).
