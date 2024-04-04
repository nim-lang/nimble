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
It might be better to use `nimble search` (explained below), to search for a specific package.

If you want to see a list of locally installed packages and their versions, use `--installed`, or `-i` for short:

    $ nimble list -i




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




## `nimble path`

The `nimble path` command will show the absolute path to the installed packages matching the specified parameters.
Since there can be many versions of the same package installed, this command will list all of them, for example:

```sh
$ nimble path itertools
/home/user/.nimble/pkgs2/itertools-0.4.0-5a3514a97e4ff2f6ca4f9fab264b3be765527c7f
/home/user/.nimble/pkgs2/itertools-0.2.0-ab2eac22ebda6512d830568bfd3052928c8fa2b9
```