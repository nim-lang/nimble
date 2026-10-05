# Use existing Nimble packages

While Nim has a relatively large standard library, chances are that at some point you will want to use some 3rd party library.
In the following sections, we will show you the most used `nimble` commands for that purpose.


## `nimble install`

The `install` command will download and install a package.
You need to pass the name of the package (or packages) you want to install.
If any of the packages depend on other Nimble packages Nimble will also install them.
Example:

```sh
$ nimble install nake
Downloading https://github.com/fowlmouth/nake using git
      ...
  Success:  nake installed successfully.

```

Nimble always fetches and installs the latest version of a package.
Note that the latest version is defined as the latest tagged version in the Git (or Mercurial) repository.
If the package has no tagged versions then the latest commit in the remote repository will be installed.
If you already have that version installed, Nimble will ask you whether you wish to overwrite your local copy.


### Installing a specific version

You can force Nimble to download the latest commit from the package's repo, for
example:

    $ nimble install nimgame@#head

This is of course Git-specific, for Mercurial, use `tip` instead of `head`.
A branch, tag, or commit hash may also be specified in the place of `head`.

Instead of specifying a VCS branch, you may also specify a concrete version or a
version range, for example:

    $ nimble install nimgame@0.5
    $ nimble install nimgame@"> 0.5"

The following version selector operators are available:

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


Nim flags provided to `nimble install` will be forwarded to the compiler when
building any binaries.
Such compiler flags can be made persistent by using Nim [configuration](https://nim-lang.org/docs/nimc.html#compiler-usage-configuration-files)
files.




### Package URLs

A valid URL to a Git or Mercurial repository can also be specified, Nimble will
automatically detect the type of the repository that the url points to and
install it.
This way, the packages which are not in the official package list can be installed.

For repositories containing the Nimble package in a subdirectory, you can
instruct Nimble about the location of your package using the `?subdir=<path>`
query parameter. For example:

    $ nimble install https://github.com/nimble-test/multi?subdir=alpha




### Local Package Development

The `install` command can also be used for locally testing or developing a Nimble package by leaving out the package name parameter.
Your current working directory must be a Nimble package and contain a valid `package.nimble` file.

Nimble will install the package residing in the current working directory when you don't specify a package name and the directory contains a `package.nimble` file.
This can be useful for developers who are locally testing their `.nimble` files before submitting them to the official package list.
See the [Create Packages guide](./create-packages.md) for more info on this.

Dependencies required for developing or testing a project can be installed by passing `--depsOnly` without specifying a package name.
Nimble will then install any missing dependencies listed in the package's `package.nimble` file in the current working directory.
Note that dependencies will be installed globally.

For example to install the dependencies for a Nimble project `myPackage`:

    $ cd myPackage
    $ nimble install --depsOnly






## `nimble list`

If you want to list *all* available packages, you can use `nimble list`, but beware: it is a very long (and not very useful) list.

Naming one or more packages restricts the output to those packages:

    $ nimble list chronos

    chronos:
      url:         https://github.com/status-im/nim-chronos (git)
      tags:        library, networking, async, asynchronous, eventloop, timers, sendfile, tcp, udp
      description: An efficient library for asynchronous programming
      license:     Apache License 2.0
      website:     https://github.com/status-im/nim-chronos

The name has to match a known package exactly, though the comparison is case insensitive.
Nimble exits with an error if it does not know the package; use `nimble search` (explained below) to look for packages by name fragment or tag instead.

Add `--ver` to also query the package's repository for the versions it has tagged:

    $ nimble list chronos --ver

    chronos:
      url:         https://github.com/status-im/nim-chronos (git)
      ...
      versions:    v4.4.0, v4.2.4, v4.2.3, v4.2.2, v4.2.0, v4.0.7, ...

Because `--ver` contacts each matching package's repository, it is worth naming the packages you care about.
`nimble list --ver` on its own queries every package Nimble knows about, one at a time.

A name may carry a version range, spelled exactly as it would be in a `requires` line, to narrow the versions reported.
Giving a range implies `--ver`:

    $ nimble list "chronos >= 4.0.4"

    chronos:
      url:         https://github.com/status-im/nim-chronos (git)
      ...
      versions:    v4.4.0, v4.2.4, v4.2.3, v4.2.2, v4.2.0, v4.0.7, v4.0.6, v4.0.5, v4.0.4

Quote the argument so the shell keeps it as one word.
Any range accepted in a `requires` line works, including `== 4.2.0` and `>= 4.0.0 & < 4.3.0`.
A range that matches nothing is not an error — the package is still listed, with a note in place of the versions:

    $ nimble list "chronos >= 99"

    chronos:
      ...
      versions:    (No tagged versions match >= 99)

Only tagged releases are matched, so a special version such as `chronos#head` reports no matches: `#head` is a branch, not a tag.

If you want to see a list of locally installed packages and their versions, use `--installed`, or `-i` for short:

    $ nimble list -i

This also accepts package names and version ranges, so `nimble list -i chronos` reports just the installed copies of chronos, and `nimble list -i "chronos >= 4.0.4"` narrows that to the installed versions in range.




## `nimble search`

If you don't want to go through the whole output of the `list` command you can use the `search` command specifying as parameters the package name and/or tags you want to filter.
Nimble will look into the known list of available packages and display only those that match the specified keywords (which can be substrings).
Example:

    $ nimble search math

    linagl:
    url:         https://bitbucket.org/BitPuffin/linagl (hg)
    tags:        library, opengl, math, game
    description: OpenGL math library
    license:     CC0
    website:     https://bitbucket.org/BitPuffin/linagl

    extmath:
    url:         git://github.com/achesak/extmath.nim (git)
    tags:        library, math, trigonometry
    description: Nim math library
    license:     MIT
    website:     https://github.com/achesak/extmath.nim

    glm:
    url:         https://github.com/stavenko/nim-glm (git)
    tags:        opengl, math, matrix, vector, glsl
    description: Port of c++ glm library with shader-like syntax
    license:     MIT
    website:     https://github.com/stavenko/nim-glm

    ...


Searches are case insensitive.

An optional `--ver` parameter can be specified to tell Nimble to query remote Git repositories for the list of versions of the packages and then print the versions.
However, please note that this can be slow as each package must be queried separately.


### nimble.directory

As an alternative for `nimble search` command, you can use [Nimble Directory website](https://nimble.directory) to search for packages.




## `nimble uninstall`

The `uninstall` command will remove an installed package.

!!! warning
    Attempting to remove a package that other packages depend on will result in an error.

    You can use the `--inclDeps` or `-i` flag to remove all dependent packages along with the package.


Similar to the `install` command you can specify a version range, for example:

    $ nimble uninstall nimgame@0.5




## `nimble lock`

The `lock` command generates or updates a package lock file.
On its own it keeps every pin it already has, only re-solving when a package's requirements changed:

```sh
$ nimble lock
```

There are two ways to move a pin, and these two ways can be used together:

- **passing a package name** relocks it and leaves the rest of the file alone:

    ```sh
    $ nimble lock chronos
    ```

- **adding `--refresh`** resolves against the package repositories instead of the cached version information, so versions published since the last lock are picked up.
With no package name it relocks everything to the newest available version:

    ```sh
    $ nimble lock --refresh          # everything, to the newest published
    $ nimble lock --refresh chronos  # just chronos, to the newest published
    ```

The distinction matters because `lock` normally resolves from Nimble's version cache.
Without `--refresh`, `nimble lock chronos` moves chronos only as far as the newest version Nimble already knows about, which may be older than what upstream has published.

!!! note

    `nimble upgrade` is a deprecated alias of `lock --refresh`; it still works but prints a warning.

### When to use `nimble lock`

*You don't have to use `nimble lock`*. Nimble can resolve your dependencies based solely on the `requires` constaints in your `.nimble` file.

Hovewer, dependency resolution finds the best match for the given constaint *at the time it's invoked*. That means, if the best match changes (for example, because a dependency is updated), two users will end up having differrent versions of the same package installed even with identical `.nimble` files: the one that had installed the dependencies gets the older best match while the other one, who installed the dependencies later, gets the newer best match.

Locking the dependencies adds a layer of control and determinism (at the cost of having to maintain your dependency updates manually). Your package will not automatically receive bug fixes but it also will not receive unexpected breaking updates. It's a compromise worth accepting for some packages.

Here are some situations where using `nimble lock` and accepting the maintenance tax associated with it is justified:

- **Collaborative development with many active contributors.** Lock your deps to make sure everyone on the team gets exactly the same environment, including bug-compatibility. Move pins with separate CI-testable commits to avoid unexpected breaking changes from updated dependencies.
- **Saving time on dependency resolution.** If your packages has many dependencies and you need to reduce time spent resolving them (for example, when you need to optimize the CI runs), resolve the deps once and lock them. Nimble will not spend time resolving and will simply install the versions from the lock file.
- **Shipping reproducible app builds.** If you distribute your app in the form of code and want to make sure any user can build the same version locally, lock the dependencies in your release and ship it with the lock files.




## `nimble refresh`

The `refresh` command is used to fetch and update the list of Nimble packages.
There is no automatic update mechanism, so you need to run this yourself if you need to *refresh* your local list of known available Nimble packages.
Example:

```sh
$ nimble refresh
    Copying local package list
    Success Package list copied.
Downloading Official package list
    Success Package list downloaded.
```

Package lists can be specified in Nimble's config.
You can also optionally supply this command with a URL if you would like to use
a third-party package list.

Some commands may remind you to run `nimble refresh` or will run it for you if they fail.

Refreshing the package list only tells Nimble which packages exist.
To also learn which *versions* of them exist, `refresh` goes on to fetch the repositories behind the packages it knows about and reports the newer versions that became visible:

```sh
$ nimble refresh
Downloading Official package list
    Success Package list downloaded.
  Refreshed 3 dependencies of myproject
      Info: Newer versions available:
              chronos 4.0.3 -> 4.0.4
```

Which packages that covers depends on where you run it:

* **Inside a package** — its dependencies, including transitive ones.
  Any `develop` dependency with a clean working copy is also moved to its newest tag; one with uncommitted changes is reported and left untouched.
* **Outside a package**, or with `-g` / `--global` — every package Nimble knows about globally: those installed in the global package directory, plus every package already in its version cache.

`nimble refresh` only updates what Nimble knows is available.
It picks no versions, writes no lock file and installs nothing, so it is safe to run at any time; use `nimble install` or `nimble lock --refresh` afterwards to actually act on what it found.

Other commands resolve against that cached version information rather than the repositories, which is why a freshly published version can stay invisible to them until the cache is updated.
Pass `--refresh` to any of them to resolve against the repositories instead:

```sh
$ nimble install --refresh   # also works with lock, upgrade, build, ...
```

Since it contacts every relevant repository, a global refresh can take a while.
It fetches several of them at a time and reports its progress as it goes; pass `--sync` to fetch them one by one instead.
To skip it entirely and update only the package list, use `--packageListOnly`:

```sh
$ nimble refresh --packageListOnly
```




## `nimble deps`

The `nimble deps` command displays the dependency tree of the current package.
It shows all direct and transitive dependencies along with their version requirements and resolved versions.

```sh
$ nimble deps
```

The output format is:

```
{PackageName} {Requirements} (@{Resolved Version})
```

For example:

```
mypackage (@1.0.0)
├── jester @>= 0.5.0 (@0.6.0)
│   └── httpbeast @>= 0.4.0 (@0.4.1)
└── chronicles @any (@0.10.3)
```

### Options

- `--format:json` - Output the dependency tree in JSON format for programmatic use.
- `-i` or `--inverted` - Show an inverted dependency tree where each package lists which packages depend on it.
- `-d` or `--direct` - Show only direct dependencies (no transitive dependencies).



## `nimble path`

The `nimble path` command will show the absolute path to the installed packages matching the specified parameters.
Since there can be many versions of the same package installed, this command will list all of them, for example:

```sh
$ nimble path itertools
/home/user/.nimble/pkgs2/itertools-0.4.0-5a3514a97e4ff2f6ca4f9fab264b3be765527c7f
/home/user/.nimble/pkgs2/itertools-0.2.0-ab2eac22ebda6512d830568bfd3052928c8fa2b9
```
