# Creating Nimble packages

In this guide you will find the information on how to create and publish new Nimble packages.



## `nimble init`

The easiest and recommended way to start a new Nimble project is to run `nimble init` in the directory in which you want to create a package, and follow the steps in the wizard.


```
$ nimble init
      Info: Package initialisation requires info which could not be inferred.
        ... Default values are shown in square brackets, press
        ... enter to use them.
      Using "myPackage" for new package name
      Using username for new package author
      Using "src" for new package source directory
    Prompt: Package type?
        ... Library - provides functionality for other packages.
        ... Binary  - produces an executable for the end-user.
        ... Hybrid  - combination of library and binary
        ... For more information see https://goo.gl/cm2RX5
     Select Cycle with 'Tab', 'Enter' when done
   Choices:> library <
             binary  
             hybrid  
```

The first choice you have to make is the type of your package.
The differences between those three options are outlined in [this document](./package-types.md).

After that, the wizard asks you about the version number of your package (default: 0.1.0), a package description, a license you want to use and the lowest Nim version that your package is compatible with.
You can press enter to use the provided default answer for each question.

```
    Prompt: Initial version of package? [0.1.0]
    Answer: 
    Prompt: Package description? [A new awesome nimble package]
    Answer: Check if a number is odd.         
    Prompt: Package License?
        ... This should ideally be a valid SPDX identifier. See https://spdx.org/licenses/.
     Select Cycle with 'Tab', 'Enter' when done
    Answer: MIT
    Prompt: Lowest supported Nim version? [2.1.1]
    Answer: 2.0.0
   Success: Package myPackage created successfully
```

After the wizard completes, the structure of your directory looks like this:

```
.
├── myPackage.nimble
├── src
│   ├── myPackage
│   │   └── submodule.nim
│   └── myPackage.nim
└── tests
    ├── config.nims
    └── test1.nim
```


The answers you provided are stored in the `.nimble` file:

```ini
# Package

version       = "0.1.0"
author        = "username"
description   = "Check if a number is odd."
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.0.0"
```


## Project structure

For a package named `foobar`, the recommended project structure is the following:

```sh
.                   # The root directory of the project
├── LICENSE
├── README.md
├── foobar.nimble   # The project .nimble file
└── src
    └── foobar.nim  # Imported via `import foobar`
└── tests           # Contains the tests
    ├── config.nims
    ├── tfoo1.nim   # First test
    └── tfoo2.nim   # Second test

```

!!! note
    When source files are placed in a `src` directory, the `.nimble` file must contain a `srcDir = "src"` directive.
    The `nimble init` command takes care of that for you.

When introducing more modules into your package, you should place them in a separate directory named `foobar` (i.e. your package's name).
For example:

```sh
.
├── ...
├── foobar.nimble
├── src
│   ├── foobar
│   │   ├── utils.nim   # Imported via `import foobar/utils`
│   │   └── common.nim  # Imported via `import foobar/common`
│   └── foobar.nim      # Imported via `import foobar`
└── ...
```

You may wish to hide certain modules in your package from the users. Create a
`private` directory for that purpose. For example:

```sh
.
├── ...
├── foobar.nimble
├── src
│   ├── foobar
│   │   ├── private
│   │   │   └── hidden.nim  # Imported via `import foobar/private/hidden`
│   │   ├── utils.nim
│   │   └── common.nim
│   └── foobar.nim
└── ...
```







## `.nimble` file

As seen above, running `nimble init` creates a basic `.nimble` file.
It can be modified to add more dependencies and/or create custom tasks, etc.


### Dependencies

If your package relies on other dependencies, you need to add them to the `.nimble` file.
Nimble currently supports the installation of packages from a local directory, a Git repository and a mercurial repository. 

```ini
...

# Dependencies

requires "nim >= 2.0.0"
requires "fizzbuzz == 1.0"
requires "https://github.com/user/pkg#5a54b5e"
requires "foobar#head"
```

Versions of cloned packages via Git or Mercurial are determined through the repository's *tags*.
When installing a package that needs to be downloaded, Nimble will check the cloned repository's tags list.

- If no tags exist, Nimble will simply install the `HEAD` of the repository.
- If tags exist, Nimble will attempt to look for tags that resemble versions (e.g. `v0.1`) and will then find the latest version out of the available tags, once it does so it will install the package after checking out the latest version.

You can force the installation of the `HEAD` of the repository by specifying `#head` after the package name in your dependency list.

There are several version selector operators you can use:

| Operator | Meaning |
| ---  | --- |
| `==` | Install the exact version. |
| `>`  | Install higher version. |
| `<`  | Install lower version. |
| `>=` | Install _at least_ the provided version. |
| `<=` | Install _at most_ the provided version. |
| `^=` | Install the latest compatible version according to [semver](https://semver.npmjs.com/). |
| `~=` | Install the latest version by increasing the last given digit
       to the highest version.


Here are some examples of the `^=` and `~=` operators:

```nim
requires "nim ^= 1.2.2"    # nim >= 1.2.2 & < 2.0.0
requires "nim ~= 1.2.2"    # nim >= 1.2.2 & < 1.3.0
requires "jester ^= 0.4.1" # jester >= 0.4.1 & < 0.5.0
requires "jester ~= 0.4.1" # jester >= 0.4.1 & < 0.5.0
requires "jester ~= 0.4"   # jester >= 0.4.0 & < 1.0.0
requires "choosenim ~= 0"  # choosenim >= 0.0.0 & < 1.0.0
requires "choosenim ^= 0"  # choosenim >= 0.0.0 & < 1.0.0
```


### NimScript compatibility

The `.nimble` file is very flexible because it is interpreted using NimScript.

Because of Nim's flexibility, the definitions remain declarative, with the added ability to use the Nim language to enrich your package specification.
For example, you can define dependencies for specific platforms using Nim's
`when` statement:

```nim
when defined(macosx):
  requires "libcurl >= 1.0.0"

when defined(windows):
  requires "puppy 1.5.4"
```



### `nimble tasks`

Another great feature of `.nimble` file is the ability to define custom Nimble package-specific commands:

```nim
task hello, "This is a hello task":
  echo "Hello World!"
```

You can then execute `nimble hello`, which will result in the following
output:

```sh
$ nimble hello
  Verifying dependencies for myPackage@0.1.0
  Executing task hello in /home/username/myPackage/myPackage.nimble
Hello world
```

You can also check what tasks are supported by the package in the current
directory by using the `nimble tasks` command, for example:

```sh
$ nimble tasks
hello     This is a hello task
```

You can place any Nim code inside these tasks, as long as that code does not access the FFI. The [nimscript module](https://nim-lang.org/docs/nimscript.html) in Nim's standard library defines additional functionality, such as the ability to execute external processes
which makes this feature very powerful.

Nimble provides an API that adds even more functionality.
For example, you can specify pre- and post- hooks for any Nimble command (including commands that you define yourself).
To do this you can add something like the following:

```nim
before hello:
  echo "About to call hello!"
```

That will result in the following output when `nimble hello` is executed:

```
$ nimble hello
  Verifying dependencies for myPackage@0.1.0
About to call hello!
  Executing task hello in /home/username/myPackage/myPackage.nimble
Hello world
```

Similar to this, an `after` block is also available for post hooks, which are executed after Nimble finished executing a command.
You can also return `false` from these blocks to stop further execution.

Tasks support two kinds of flags: `nimble <compflags> task <runflags>`.

Compile flags are those specified before the task name and are forwarded to the Nim compiler that runs the `.nimble` task.
This enables setting `--define:xxx` values that can be checked with `when defined(xxx)` in the task, and other compiler flags that are applicable in Nimscript mode.

Run flags are those after the task name and are available as command-line arguments to the task.
They can be accessed as usual from `commandLineParams: seq[string]`.

In order to forward compiler flags to `exec("nim ...")` calls executed within a custom task, the user needs to specify these flags as run flags which will then need to be manually accessed and forwarded in the task.







## `nimble test`

Nimble offers a pre-defined `test` task that compiles and runs all files
in the `tests` directory beginning with letter `t` in their filename.
Nim flags provided to `nimble test` will be forwarded to the compiler when building
the tests.

If we run `nimble test` on our example project created in sections above, the default `tests/test1.nim` (pre-populated with one test) will run with the following output:

```sh
$ nimble test
  Verifying dependencies for myPackage@0.1.0
  Compiling /home/username/myPackage/tests/test1 (from package myPackage) using c backend
[OK] can add
   Success: Execution finished
   Success: All tests passed
```


You may wish to override the default `test` task in your `.nimble` file.
Here is a real-world example of a custom `test` task, which runs tests from seven different test files:

```nim
task test, "General tests":
  for file in ["tsources.nim", "tblocks.nim", "tnimib.nim", "trenders.nim"]:
    exec "nim r --hints:off tests/" & file
  for file in ["tblocks.nim", "tnimib.nim", "trenders.nim"]:
    exec "nim r --hints:off -d:nimibCodeFromAst tests/" & file
```



## `nimble c`

The `c` (or `compile`, `js`, `cc`, `cpp`) command can be used by developers to compile individual modules inside their package.
All options passed to Nimble will also be passed to the Nim compiler during compilation.
For example:

Nimble will use the backend specified in the package's `.nimble` file if the command `c` or `compile` is specified.
The more specific `js`, `cc`, `cpp` can be used to override that.



 
## `nimble build`

The `build` command is mostly used by developers who want to test building their `.nimble` package.
This command will build the package with default flags, i.e. a debug build which includes stack traces but no GDB debug information.
The `install` command will build the package in release mode instead.

Nim flags provided to `nimble build` will be forwarded to the compiler.
Such compiler flags can be made persistent by using Nim [configuration](https://nim-lang.org/docs/nimc.html#compiler-usage-configuration-files) files.




## `nimble run`

The `run` command can be used to build and run any binary specified in your package's `bin` list.
The binary needs to be specified after any compilation flags if there are several binaries defined.
Any flags after the binary or `--` are passed to the binary when it is run.
It is possible to run a binary from some dependency package.
To do this pass the `--package, -p` option to Nimble.
For example:

```sh
nimble --package:foo run <compilation_flags> bar <run_flags>
```



## `nimble check`

The `check` command will read your package's `.nimble` file.
It will then verify that the package's structure is valid.

Example:

```
$ nimble check
    Error: Package 'x' has an incorrect structure.
    It should contain a single directory hierarchy for source files, named 'x',
    but file 'foobar.nim' is in a directory named 'incorrect' instead.
    This will be an error in the future.
    Hint: If 'incorrect' contains source files for building 'x', rename it to 'x'.
    Otherwise, prevent its installation by adding `skipDirs = @["incorrect"]`
    to the .nimble file.
  Failure: Validation failed
```

When using the `check` command, the development mode dependencies are also validated against the lock file.
The following reasons for validation failure are possible:

* The package directory is not under version control.
* The package working copy directory is not in clean state.
* Current VCS revision is not pushed on any remote.
* The working copy needs sync.
* The working copy needs lock.
* The working copy needs merge or re-base.




## `nimble install`

While `nimble install <packageName>` is used to download and install an existing package (see [this guide](./use-packages.md#nimble-install)),
it can also be used for locally testing or developing a Nimble package by leaving out the package name parameter.
Your current working directory must be a Nimble package and contain a valid `package.nimble` file.

Nimble will install the package residing in the current working directory when you don't specify a package name and the directory contains a `package.nimble` file.
This can be useful for developers who are locally testing their `.nimble` files before submitting them to the official package list.

Dependencies required for developing or testing a project can be installed by passing `--depsOnly` without specifying a package name.
Nimble will then install any missing dependencies listed in the package's `package.nimble` file in the current working directory.
Note that dependencies will be installed globally.

For example, to install the dependencies:

    $ nimble install --depsOnly




## `nimble dump`

Outputs information about the package in the current working directory in an ini-compatible format.
Useful for tools wishing to read metadata about Nimble packages who do not want to use the NimScript evaluator.

The format can be specified with `--json` or `--ini` (and defaults to `--ini`).
Use `nimble dump pkg` to dump information about provided `pkg` instead.




## `nimble publish`

Publishing packages isn't a requirement, but doing so allows people to associate a specific name to a URL pointing to your package.
This mapping is stored in [the official packages repository](https://github.com/nim-lang/packages).

This repository contains a `packages.json` file that lists all the published packages.
It contains a set of package names with associated metadata.
You can read more about this metadata in the
[readme for the packages repository](https://github.com/nim-lang/packages#readme).

To publish your package, you can do it in two different ways:

- Semi-automatically, by running `nimble publish`, which requires a valid GitHub account with a personal access token.
   The token is stored in `$nimbleDir/github_api_token`, which can be replaced if you need to update/replace your token.

- Manually, by forking the [packages repository](https://github.com/nim-lang/packages), adding an entry into the `packages.json` file for your packages, and creating a pull request with your changes.

You need to do this only once, i.e. no need to do it every time you increase the version of your package.



### Releasing a new version

Version releases are done by creating a tag in your Git or Mercurial repository.

Whenever you want to release a new version, you should remember to first increment the version in your `.nimble` file and commit your changes. Only after that is done should you tag the release.

To summarize, the steps for release are:

1. Increment the version in your `.nimble` file.
2. Commit your changes.
3. Tag your release, by for example running `git tag v0.2.0`.
4. Push your tags and commits.

Once the new tag is in the remote repository, Nimble will be able to detect the new version.


#### Git Version Tagging

Use dot-separated numbers to represent the release version in the git tag label. 
Nimble will parse these git tag labels to know which versions of a package are published.

```sh
v0.2.0        # 0.2.0
v1            # 1
v1.2.3-zuzu   # 1.2.3
foo-1.2.3.4   # 1.2.3.4
```
