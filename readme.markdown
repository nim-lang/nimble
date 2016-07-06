# Nimble [![Build Status](https://travis-ci.org/nim-lang/nimble.svg?branch=master)](https://travis-ci.org/nim-lang/nimble)

Nimble is a *beta*-grade *package manager* for the [Nim programming
language](http://nim-lang.org).

Interested in learning **how to create a package**? Skip directly to that section
[here](#creating-packages).

## Contents

- [Installation](#installation)
	- [Unix](#unix)
	- [Windows](#windows)
		- [Using the pre-built archives](#using-the-pre-built-archives)
		- [From source](#from-source)
- [Nimble's folder structure and packages](#nimbles-folder-structure-and-packages)
- [Nimble usage](#nimble-usage)
	- [nimble refresh](#nimble-refresh)
	- [nimble install](#nimble-install)
	- [nimble uninstall](#nimble-uninstall)
	- [nimble build](#nimble-build)
	- [nimble c](#nimble-c)
	- [nimble list](#nimble-list)
	- [nimble search](#nimble-search)
	- [nimble path](#nimble-path)
	- [nimble init](#nimble-init)
	- [nimble publish](#nimble-publish)
	- [nimble tasks](#nimble-tasks)
	- [nimble dump](#nimble-dump)
- [Configuration](#configuration)
- [Creating Packages](#creating-packages)
	- [The new NimScript format](#the-new-nimscript-format)
	- [Libraries](#libraries)
	- [Binary packages](#binary-packages)
	- [Hybrids](#hybrids)
	- [Dependencies](#dependencies)
	- [Nim compiler](#nim-compiler)
	- [Versions](#versions)
- [Submitting your package to the package list.](#submitting-your-package-to-the-package-list)
- [.nimble reference](#nimble-reference)
	- [[Package]](#package)
		- [Required](#required)
		- [Optional](#optional)
	- [[Deps]/[Dependencies]](#depsdependencies)
		- [Optional](#optional)
- [Troubleshooting](#troubleshooting)
- [Contribution](#contribution)
- [About](#about)

## Installation

The latest version of Nimble (in the master branch) is primarily tested with
the latest version of the Nim compiler (in the devel branch). You can be sure
that Nimble will compile with that version of the compiler (a green travis
build status is also a good sign that this is the case).

The latest version of Nimble (0.7.4) requires a version of Nim greater than
or equal to 0.13.0. That being said, the latest version of Nim is recommended.

Nimble has some runtime dependencies on external tools, these tools are
used to download Nimble packages.
For
instance, if a package is hosted on [Github](https://github.com) you require to
have [git](http://www.git-scm.com) installed and added to your environment
``PATH``. Same goes for [Mercurial](http://mercurial.selenic.com) repositories
on [Bitbucket](https://bitbucket.org). Nimble packages are typically hosted in
Git repositories so you may be able to get away without installing Mercurial.

**Warning:** Ensure that you have a fairly recent version of Git installed.
If the version is less recent than 1.9.0 then Nimble may have trouble using it.
See [this issue](https://github.com/nim-lang/nimble/issues/105) for more
info.

The following sections give platform-specific instructions on how to
compile and install Nimble.

### Unix

On Unix-like operating systems Nimble can be compiled and installed with two
simple
commands. After successfully grabbing the latest Nim compiler simply execute
the following commands to clone nimble, compile it and then install it.

    git clone https://github.com/nim-lang/nimble.git
    cd nimble
    git clone -b v0.14.2 --depth 1 https://github.com/nim-lang/nim vendor/nim
    nim -d:release c -r src/nimble -y install

After these steps are completed successfully, nimble will be installed
in ``~/.nimble/bin``. You must then add
``~/.nimble/bin`` to your ``$PATH``. Updating nimble can then be done by
executing ``nimble install nimble``.

### Windows

You can install Nimble via a pre-built installation archive which is
available on the [releases](https://github.com/nim-lang/nimble/releases) page.
Alternatively, you can also install Nimble from source, but the instructions
for doing so are a bit different on Windows.

#### Using the pre-built archives

Download the latest release archive from the
[releases](https://github.com/nim-lang/nimble/releases) page. These archives
will have a filename of the form ``nimble-x_win32`` where ``x`` is the
current version.

Once you download that archive unzip it and execute the ``install.bat`` file.
One important thing to note is that this installation requires you have
the Nim compiler in your PATH. Once the installation completes you should
add ``C:\Users\YourName\.nimble\bin`` to your PATH.

#### From source

On Windows installing Nimble from source is slightly more complex:

    git clone https://github.com/nim-lang/nimble.git
    cd nimble
    nim -d:release c src/nimble
    cp src/nimble.exe src/nimble1.exe
    src/nimble1.exe install

This is required because Windows will lock the process which is being run, but
during installation Nimble recompiles itself causing an error.
Once the installation completes you should
add ``C:\Users\YourName\.nimble\bin`` to your PATH.

## Nimble's folder structure and packages

Nimble stores everything that has been installed in ``~/.nimble`` on Unix systems
and in your ``$home/.nimble`` on Windows. Libraries are stored in
``$nimbleDir/pkgs``, and binaries are stored in ``$nimbleDir/bin``. Most Nimble
packages will provide ``.nim`` files and some documentation. The Nim
compiler is aware of Nimble and will automatically find the modules so you can
``import modulename`` and have that working without additional setup.

However, some Nimble packages can provide additional tools or commands. If you
don't add their location (``$nimbleDir/bin``) to your ``$PATH`` they will not
work properly and you won't be able to run them.

## Nimble usage

Once you have Nimble installed on your system you can run the ``nimble`` command
to obtain a list of available commands.

### nimble refresh

The ``refresh`` command is used to fetch and update the list of Nimble packages
(see below). There is no automatic update mechanism, so you need to run this
yourself if you need to *refresh* your local list of known available Nimble
packages.  Example:

    $ nimble refresh
    Downloading package list from https://.../packages.json
    Done.

Some commands may remind you to run ``nimble refresh`` or will run it for you if
they fail.

You can also optionally supply this command with a URL if you would like to use
a third-party package list.

Package lists can be specified in Nimble's config. Take a look at the
config section below to see how to do this.

### nimble install

The ``install`` command will download and install a package. You need to pass
the name of the package (or packages) you want to install. If any of the
packages depend on other Nimble packages Nimble will also install them.
Example:

    $ nimble install nake
    Downloading nake into /tmp/nimble/nake...
    Executing git...
    ...
    nake installed successfully

Nimble always fetches and installs the latest version of a package. Note that
latest version is defined as the latest tagged version in the git (or hg)
repository, if the package has no tagged versions then the latest commit in the
remote repository will be installed. If you already have that version installed
Nimble will ask you whether you wish it to overwrite your local copy.

You can force Nimble to download the latest commit from the package's repo, for
example:

    $ nimble install nimgame@#head

This is of course git specific, for hg use ``tip`` instead of ``head``. A
branch, tag, or commit hash may also be specified in the place of ``head``.

Instead of specifying a VCS branch you may also specify a version range, for
example:

    $ nimble install nimgame@"> 0.5"

In this case a version which is greater than ``0.5`` will be installed.

If you don't specify a parameter and there is a ``package.nimble`` file in your
current working directory then Nimble will install the package residing in
the current working directory. This can be useful for developers who are testing
locally their ``.nimble`` files before submitting them to the official package
list. See the [Creating Packages](#creating-packages) section for more info on this.

A URL to a repository can also be specified, Nimble will automatically detect
the type of the repository that the url points to and install it.

### nimble uninstall

The ``uninstall`` command will remove an installed package. Attempting to remove
a package which other packages depend on is disallowed and will result in an
error. You must currently manually remove the reverse dependencies first.

Similar to the ``install`` command you can specify a version range, for example:

    $ nimble uninstall nimgame@0.5

### nimble build

The ``build`` command is mostly used by developers who want to test building
their ``.nimble`` package. This command will build the package in debug mode,
without installing anything. The ``install`` command will build the package
in release mode instead.

### nimble c

The ``c`` (or ``compile``, ``js``, ``cc``, ``cpp``) command can be used by
developers to compile individual modules inside their package. All options
passed to Nimble will also be passed to the Nim compiler during compilation.

Nimble will use the backend specified in the package's ``.nimble`` file if
the command ``c`` or ``compile`` is specified. The more specific ``js``, ``cc``,
``cpp`` can be used to override that.

### nimble list

The ``list`` command will display the known list of packages available for
Nimble. An optional ``--ver`` parameter can be specified to tell Nimble to
query remote git repositories for the list of versions of the packages and to
then print the versions. Please note however that this can be slow as each
package must be queried separately.

### nimble search

If you don't want to go through the whole output of the ``list`` command you
can use the ``search`` command specifying as parameters the package name and/or
tags you want to filter. Nimble will look into the known list of available
packages and display only those that match the specified keywords (which can be
substrings). Example:

    $ nimble search math
    linagl:
      url:         https://bitbucket.org/BitPuffin/linagl (hg)
      tags:        library, opengl, math, game
      description: OpenGL math library
      license:     CC0

    extmath:
      url:         git://github.com/achesak/extmath.nim (git)
      tags:        library, math, trigonometry
      description: Nim math library
      license:     MIT

Searches are case insensitive.

An optional ``--ver`` parameter can be specified to tell Nimble to
query remote git repositories for the list of versions of the packages and to
then print the versions. Please note however that this can be slow as each
package must be queried separately.

### nimble path

The nimble ``path`` command will show the absolute path to the installed
packages matching the specified parameters. Since there can be many versions of
the same package installed, the ``path`` command will always show the latest
version. Example:

    $ nimble path argument_parser
    /home/user/.nimble/pkgs/argument_parser-0.1.2

Under Unix you can use backticks to quickly access the directory of a package,
which can be useful to read the bundled documentation. Example:

    $ pwd
    /usr/local/bin
    $ cd `nimble path argument_parser`
    $ less README.md

### nimble init

The nimble ``init`` command will start a simple wizard which will create
a quick ``.nimble`` file for your project.

As of version 0.7.0, the ``.nimble`` file that this command creates will
use the new NimScript format.
Check out the [Creating Packages](#creating-packages) section for more info.

### nimble publish

Publishes your Nimble package to the official Nimble package repository.

**Note:** Requires a valid Github account.

### nimble tasks

For a nimble package in the current working directory, list the tasks which that
package defines. This is only supported for packages utilising the new
nimscript .nimble files.

### nimble dump

Outputs information about the package in the current working directory in
an ini-compatible format. Useful for tools wishing to read metadata about
Nimble packages who do not want to use the NimScript evaluator.

## Configuration

At startup Nimble will attempt to read ``~/.config/nimble/nimble.ini`` on Linux
(on Windows it will attempt to read
``C:\Users\<YourUser>\AppData\Roaming\nimble\nimble.ini``).

The format of this file corresponds to the ini format with some Nim
enhancements. For example:

```ini
nimbleDir = r"C:\Nimble\"

[PackageList]
name = "CustomPackages"
url = "http://mydomain.org/packages.json"
```

You can currently configure the following in this file:

* ``nimbleDir`` - The directory which nimble uses for package installation.
  **Default:** ``~/.nimble/``
* ``chcp`` - Whether to change the current code page when executing Nim
  application packages. If ``true`` this will add ``chcp 65001`` to the
  .cmd stubs generated in ``~/.nimble/bin/``.
  **Default:** ``true``
* ``[PackageList]`` + ``name`` + ``url`` - You can use this section to specify
  a new custom package list. Multiple package lists can be specified. Nimble
  defaults to the "Official" package list, you can override it by specifying
  a ``[PackageList]`` section named "official". Multiple URLs can be specified
  under each section, Nimble will try each in succession if
  downloading from the first fails.
* ``cloneUsingHttps`` - Whether to replace any ``git://`` inside URLs with
  ``https://``.
  **Default: true**
* ``httpProxy`` - The URL of the proxy to use when downloading package listings.
  Nimble will also attempt to read the ``http_proxy`` and ``https_proxy``
  environment variables.
  **Default: ""**

## Creating Packages

Nimble works on git repositories as its primary source of packages. Its list of
packages is stored in a JSON file which is freely accessible in the
[nim-lang/packages repository](https://github.com/nim-lang/packages).
This JSON file provides nimble with the required Git URL to clone the package
and install it. Installation and build instructions are contained inside a
ini-style file with the ``.nimble`` file extension. The nimble file shares the
package's name, i.e. a package
named "foobar" should have a corresponding ``foobar.nimble`` file.

These files specify information about the package including its name, author,
license, dependencies and more. Without one Nimble is not able to install
a package.

A .nimble file can be created easily using Nimble's ``init`` command. This
command will ask you a bunch of questions about your package, then generate a
.nimble file for you.

**Note:** As of version 0.7.0, the ``init`` command generates .nimble files
using the new NimScript format. Take a look at the next section for more
information.

A bare minimum .nimble file follows:

```ini
[Package]
name          = "ProjectName"
version       = "0.1.0"
author        = "Your Name"
description   = "Example .nimble file."
license       = "MIT"

[Deps]
Requires: "nim >= 0.10.0"
```

You may omit the dependencies entirely, but specifying the lowest version
of the Nim compiler required is recommended.

Nimble currently supports installation of packages from a local directory, a
git repository and a mercurial repository. The .nimble file must be present in
the root of the directory or repository being installed.

### The new NimScript format

**Warning:** This feature is still very experimental. You are encouraged to
try it, but be aware that it may change significantly in the future or
may even be removed completely!

Version 0.7.0 of Nimble introduces support for evaluating .nimble files
as Nim code. This means that you can define metadata about your package
using the Nim programming language.

Because of Nim's flexibility the definitions remain declarative. With the added
ability of using the Nim language to enrich your package specification.
For example, you can define dependencies for specific platforms using Nim's
``when`` statement.

The ini example above looks like this in the NimScript format:

```nim
# Package

version     = "0.1.0"
author      = "Your Name"
description = "Example .nimble file."
license     = "MIT"

# Deps

requires "nim >= 0.10.0"
```

The format is indeed very similar to the ini format. Another great feature
is the ability to define custom Nimble package-specific commands. These are
defined in the .nimble files of course.

```nim
task hello, "This is a hello task":
  echo("Hello World!")
```

You can then execute ``nimble hello``, which will result in the following
output:

```
Executing task hello in /Users/user/projects/pkg/pkg.nimble
Hello World!
```

You can place any Nim code inside these tasks. As long as that code does not
access the FFI. The ``nimscript``
[module](http://nim-lang.org/docs/nimscript.html) in Nim's standard library defines
additional functionality such as the ability to execute external processes
which makes this feature very powerful.

You can also check what tasks are supported by the package in the current
directory by using the ``tasks`` command.

Nimble provides an API which adds even more functionality. For example,
you can specify
pre and post hooks for any Nimble command (including commands that
you define yourself). To do this you can add something like the following:

```nim
before hello:
  echo("About to call hello!")
```

That will result in the following output when ``nimble hello`` is executed (you
must also specify the ``task`` shown above).

```
Executing task hello in /Users/user/projects/pkg/pkg.nimble
About to call hello!
Hello World!
```

Similar to this an ``after`` block is also available for post hooks,
which are executed after Nimble finished executing a command. You can
also return ``false`` from these blocks to stop further execution.

The ``nimscriptapi.nim`` module specifies this and includes other definitions
which are also useful. Take a look at it for more information.

### Libraries

Library packages are likely the most popular form of Nimble packages. They are
meant to be used by other library packages or the ultimate binary packages.

When nimble installs a library it will copy all the files in the package
into ``$nimbleDir/pkgs/pkgname-ver``. It's up to the package creator to make sure
that the package directory layout is correct, this is so that users of the
package can correctly import the package.

By convention, it is suggested that the layout be as follows. The directory
layout is determined by the nature of your package, that is, whether your
package exposes only one module or multiple modules.

If your package exposes only a single module, then that module should be
present in the root directory (the directory with the .nimble file) of your git
repository, it is recommended that in this case you name that module whatever
your package's name is. A good example of this is the
[jester](https://github.com/dom96/jester) package which exposes the ``jester``
module. In this case the jester package is imported with ``import jester``.

If your package exposes multiple modules then the modules should be in a
``PackageName`` directory. This will allow for a certain measure of isolation
from other packages which expose modules with the same names. In this case
the package's modules will be imported with ``import PackageName/module``.

You are free to combine the two approaches described.

In regards to modules which you do **not** wish to be exposed. You should place
them in a ``PackageName/private`` directory. Your modules may then import these
private modules with ``import PackageName/private/module``. This directory
structure may be enforced in the future.

All files and folders in the directory of where the .nimble file resides will be
copied as-is, you can however skip some directories or files by setting
the ``SkipDirs``, ``SkipFiles`` or ``SkipExt`` options in your .nimble file.
Directories and files can also be specified on a *whitelist* basis, if you
specify either of ``InstallDirs``, ``InstallFiles`` or ``InstallExt`` then
Nimble will **only** install the files specified.

### Binary packages

These are application packages which require building prior to installation.
A package is automatically a binary package as soon as it sets at least one
``bin`` value, like so:

```ini
bin = "main" # NimScript config expects a seq instead, e.g. @["main"]
```

In this case when ``nimble install`` is invoked, nimble will build the ``main.nim``
file, copy it into ``$nimbleDir/pkgs/pkgname-ver/`` and subsequently create a
symlink to the binary in ``$nimbleDir/bin/``. On Windows a stub .bat file is
created instead.

Other files will be copied in the same way as they are for library packages.

Binary packages should not install .nim files so you should include
``SkipExt = "nim"`` in your .nimble file, unless you intend for your package to
be a binary/library combo which is fine.

Dependencies are automatically installed before building. Before publishing your
package you should ensure that the dependencies you specified are correct.
You can do this by running ``nimble build`` or ``nimble install`` in the directory
of your package.

### Hybrids

One thing to note about library and binary package hybrids is that your binary
may share the name of the package. This will mean that you will
not be able to put your .nim files in a ``pkgname`` directory. The reason you
will not be able to do this is because binaries on some operating systems
do not have an extension so they will clash with a directory of the same name.

The current
convention to get around this problem is to append ``pkg`` to the name as is
done for nimble.

### Dependencies

Dependencies are specified under the ``[Deps]`` section in a nimble file.
The ``requires`` key field is used to specify them. For example:

```ini
[Deps]
Requires: "nim >= 0.10.0, jester > 0.1 & <= 0.5"
```

Dependency lists support version ranges. These versions may either be a concrete
version like ``0.1``, or they may contain any of the less-than (``<``),
greater-than (``>``), less-than-or-equal-to (``<=``) and greater-than-or-equal-to
(``>=``). Two version ranges may be combined using the ``&`` operator for example:
``> 0.2 & < 1.0`` which will install a package with the version greater than 0.2
and less than 1.0.

Specifying a concrete version as a dependency is not a good idea because your
package may end up depending on two different versions of the same package.
If this happens Nimble will refuse to install the package. Similarly you should
not specify an upper-bound as this can lead to a similar issue.

In addition to versions you may also specify git/hg tags, branches and commits.
These have to be concrete however. This is done with the ``#`` character,
for example: ``jester#head``. Which will make your package depend on the
latest commit of Jester.

### Nim compiler

The Nim compiler cannot read .nimble files. Its knowledge of Nimble is
limited to the ``nimblePaths`` feature which allows it to use packages installed
in Nimble's package directory when compiling your software. This means that
it cannot resolve dependencies, and it can only use the latest version of a
package when compiling.

When Nimble builds your package it actually executes the Nim compiler.
It resolves the dependencies and feeds the path of each package to
the compiler so that it knows precisely which version to use.

This means that you can safely compile using the compiler when developing your
software, but you should use nimble to build the package before publishing it
to ensure that the dependencies you specified are correct.

### Versions

Versions of cloned packages via git or mercurial are determined through the
repository's *tags*.

When installing a package which needs to be downloaded, after the download is
complete and if the package is distributed through a VCS, nimble will check the
cloned repository's tags list. If no tags exist, nimble will simply install the
HEAD (or tip in mercurial) of the repository. If tags exist, nimble will attempt
to look for tags which resemble versions (e.g. v0.1) and will then find the
latest version out of the available tags, once it does so it will install the
package after checking out the latest version.

You can force the installation of the HEAD of the repository by specifying
``#head`` after the package name in your dependency list.

## Submitting your package to the package list.

Nimble's packages list is stored on github and everyone is encouraged to add
their own packages to it! Take a look at
[nim-lang/packages](https://github.com/nim-lang/packages) to learn more.

## .nimble reference

### [Package]

#### Required

* ``name`` - The name of the package. *(This is not required in the new NimScript format)*
* ``version`` - The *current* version of this package. This should be incremented
  **before** tagging the current version using ``git tag`` or ``hg tag``.
* ``author`` - The name of the author of this package.
* ``description`` - A string describing the package.
* ``license`` - The name of the license in which this package is licensed under.

#### Optional

* ``SkipDirs`` - A list of directory names which should be skipped during
  installation, separated by commas.
* ``SkipFiles`` - A list of file names which should be skipped during
  installation, separated by commas.
* ``SkipExt`` - A list of file extensions which should be skipped during
  installation, the extensions should be specified without a leading ``.`` and
  should be separated by commas.
* ``InstallDirs`` - A list of directories which should exclusively be installed,
  if this option is specified nothing else will be installed except the dirs
  listed here, the files listed in ``InstallFiles``, the files which share the
  extensions listed in ``InstallExt``, the .nimble file and the binary
  (if ``bin`` is specified). Separated by commas.
* ``InstallFiles`` - A list of files which should be exclusively installed,
  this complements ``InstallDirs`` and ``InstallExt``. Only the files listed
  here, directories listed in ``InstallDirs``, files which share the extension
  listed in ``InstallExt``, the .nimble file and the binary (if ``bin`` is
  specified) will be installed. Separated by commas.
* ``InstallExt`` - A list of file extensions which should be exclusively
  installed, this complements ``InstallDirs`` and ``InstallFiles``.
  Separated by commas.
* ``srcDir`` - Specifies the directory which contains the .nim source files.
  **Default**: The directory in which the .nimble file resides; i.e. root dir of
  the package.
* ``binDir`` - Specifies the directory where ``nimble build`` will output
  binaries.
  **Default**: The directory in which the .nimble file resides; i.e.
  root dir of the package.
* ``bin`` - A list of files which should be built separated by commas with
  no file extension required. This option turns your package into a *binary
  package*, nimble will build the files specified and install them appropriately.
* ``backend`` - Specifies the backend which will be used to build the files
  listed in ``bin``. Possible values include: ``c``, ``cc``, ``cpp``, ``objc``,
  ``js``.
  **Default**: c

### [Deps]/[Dependencies]

#### Optional

* ``requires`` - Specified a list of package names with an optional version
  range separated by commas.
  **Example**: ``nim >= 0.10.0, jester``; with this value your package will
  depend on ``nim`` version 0.10.0 or greater and on any version of ``jester``.

## Troubleshooting

* ```SSL support is not available. Cannot connect over SSL. [HttpRequestError]```

Make sure that nimble is configured to run with SSL, adding a ```-d:ssl```
flag to the file ```src/nimble.nim.cfg```.
After that, you can run ```src/nimble install``` and overwrite the existing
installation.

## Contribution

If you would like to help, feel free to fork and make any additions you see fit
and then send a pull request.

If you have any questions about the project you can ask me directly on github,
ask on the Nim [forum](http://forum.nim-lang.org), or ask on Freenode in
the #nim channel.

## About

Nimble has been written by [Dominik Picheta](http://picheta.me/) with help from
a number of
[contributors](https://github.com/nim-lang/nimble/graphs/contributors).
It is licensed under the BSD license (Look at license.txt for more info).
