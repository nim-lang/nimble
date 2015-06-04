# Nimble

Nimble is a *beta*-grade *package manager* for the [Nim programming
language](http://nim-lang.org).

**Note:** This readme explains how to install and use nimble. It does not
explain how to create nimble packages. Take a look at the
[developers.markdown file](developers.markdown) for information regarding
package creation.

## Installation

You will need version 0.9.6 or better (OSX users **have** to use the developer
version 0.10.1 or better) of the [Nim
compiler](http://nim-lang.org/download.html). To run nimble you will need to
have installed some of the tools it depends on to check out source code. For
instance, if a package is hosted on [Github](https://github.com) you require to
have [git](http://www.git-scm.com) installed and added to your environment
``PATH``. Same goes for [Mercurial](http://mercurial.selenic.com) repositories
on [Bitbucket](https://bitbucket.org). On Windows you will also need [OpenSSL
DLLs](https://www.openssl.org) for secure network connections.

### Unix

On Unix operating systems Nimble can be compiled and installed with two simple
commands. After successfully grabbing the latest Nim compiler simply execute
the following commands to clone nimble, compile it and then install it.

    git clone https://github.com/nim-lang/nimble.git
    cd nimble
    nim c -r src/nimble install

After these steps nimble should be compiled and installed. You should then add
``~/.nimble/bin`` to your ``$PATH``. Updating nimble can then be done by
executing ``nimble install nimble``.

### Windows

You can install via a pre-built installation archive which is
available on the [releases](https://github.com/nim-lang/nimble/releases) page
or from source.

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
    nim c src\nimble
    cp src\nimble.exe src\nimble1.exe
    src\nimble1.exe install

This is required because Windows will lock the process which is being run and
during installation Nimble will recompile itself.
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

### nimble update

The ``update`` command is used to fetch and update the list of Nimble packages
(see below). There is no automatic update mechanism, so you need to run this
yourself if you need to *refresh* your local list of known available Nimble
packages.  Example:

    $ nimble update
    Downloading package list from https://.../packages.json
    Done.

Some commands may remind you to run ``nimble update`` or will run it for you if
they fail.

You can also optionally supply this command with a URL if you would like to use
a third-party package list.

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
list. See [developers.markdown](developers.markdown) for more info on this.

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

If you are a developer willing to produce new Nimble packages please read the
[developers.markdown file](developers.markdown) for detailed information.

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

## Configuration

At startup Nimble will attempt to read ``$AppDir/nimble/nimble.ini``,
where ``$AppDir`` is ``~/.config/`` on Linux and
``C:\Users\<YourUser>\AppData\Roaming\`` on Windows.

The format of this file corresponds to the ini format with some Nim
enhancements. For example:

```ini
nimbleDir = r"C:\Nimble\"
```

You can currently configure the following in this file:

* ``nimbleDir`` - The directory which nimble uses for package installation.
  **Default:** ``~/.nimble/``
* ``chcp`` - Whether to change the current code page when executing Nim
  application packages. If ``true`` this will add ``chcp 65001`` to the
  .cmd stubs generated in ``~/.nimble/bin/``.
  **Default:** ``true``

## Packages

Nimble works on git repositories as its primary source of packages. Its list of
packages is stored in a JSON file which is freely accessible in the
[nim-lang/packages repository](https://github.com/nim-lang/packages).
This JSON file provides nimble with the required Git URL to clone the package
and install it. Installation and build instructions are contained inside a
ini-style file with the ``.nimble`` file extension. The nimble file shares the
package's name.

## Contribution

If you would like to help, feel free to fork and make any additions you see fit
and then send a pull request. If you are a developer willing to produce new
Nimble packages please read the [developers.markdown file](developers.markdown)
for detailed information.

If you have any questions about the project you can ask me directly on github,
ask on the Nim [forum](http://forum.nim-lang.org), or ask on Freenode in
the #nim channel.

## About

Nimble has been written by [Dominik Picheta](http://picheta.me/) with help from
a number of
[contributors](https://github.com/nim-lang/nimble/graphs/contributors).
It is licensed under the BSD license (Look at license.txt for more info).
