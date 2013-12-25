# Babel

Babel is a *beta*-grade *package manager* for the [Nimrod programming
language](http://nimrod-lang.org).

## Installation

You will need the latest [Nimrod compiler from
github](https://github.com/Araq/Nimrod) to compile babel (version 0.9.2 may
work).

Once you have the latest Nimrod compiler you can compile babel by executing the
following sequence of commands to clone the repository, compile babel, then
install itself:

    git clone https://github.com/nimrod-code/babel.git
    cd babel/src
    nimrod c -d:release babel
    cd ..
    ./src/babel install

After these steps babel should be compiled and installed. You should then add
``~/.babel/bin`` to your ``$PATH``. If you want to get rid of the git checkout
and use babel to keep itself up to date, run ``babel install babel`` at least
once to install as a normal binary package.

**Note**: On **Windows** you must rename ``babel.exe`` to ``babel1.exe`` and
subsequently run ``babel1.exe install``. This is because Windows will lock
the process which is being run.

## Babel's folder structure and packages

Babel stores everything that has been installed in ``~/.babel`` on Unix systems
and in your ``$home/.babel`` on Windows. Libraries are stored in
``$babelDir/pkgs``, and binaries are stored in ``$babelDir/bin``. Most Babel
packages will provide ``.nim`` files and some documentation. The Nimrod
compiler is aware of Babel and will automatically find the modules so you can
``import modulename`` and have that working without additional setup.

However, some Babel packages can provide additional tools or commands. If you
don't add their location (``$babelDir/bin``) to your ``$PATH`` they will not
work properly and you won't be able to run them.

## Babel usage

Once you have Babel installed on your system you can run the ``babel`` command
to obtain a list of available commands.

### babel update

The ``update`` command is used to fetch and update the list of Babel packages
(see below). There is no automatic update mechanism, so you need to run this
yourself if you need to *refresh* your local list of known available Babel
packages.  Example:

    $ babel update
    Downloading package list from https://.../packages.json
    Done.

Some commands may remind you to run ``babel update`` or will run it for you if
they fail.

You can also optionally supply this command with a URL if you would like to use
a third-party package list.

### babel install

The ``install`` command will download and install a package. You need to pass
the name of the package (or packages) you want to install. If any of the
packages depend on other Babel packages Babel will also install them.
Example:

    $ babel install nake
    Downloading nake into /tmp/babel/nake...
    Executing git...
    ...
    nake installed successfully

Babel always fetches and installs the latest version of a package. Note that
latest version is defined as the latest tagged version in the git (or hg)
repository, if the package has no tagged versions then the latest commit in the
remote repository will be installed. If you already have that version installed 
Babel will ask you whether you wish it to overwrite your local copy.

You can force Babel to download the latest commit from the package's repo, for
example:

    $ babel install nimgame#head

This is of course git specific, for hg use ``tip`` instead of ``head``. A
branch, tag, or commit hash may also be specified in the place of ``head``.

If you don't specify a parameter and there is a ``package.babel`` file in your
current working directory Babel will install the package residing in
the current working directory. This can be useful for developers who are testing
locally their ``.babel`` files before submitting them to the official package 
list. See [developers.markdown](developers.markdown) for more info on this.

A URL to a repository can also be specified, Babel will automatically detect
the type of the repository that the url points to and install it.

### babel build

The ``build`` command is mostly used by developers who want to test building
their ``.babel`` package. The ``install`` command calls ``build`` implicitly,
so there is rarely any reason to use this command directly.

### babel list

The ``list`` command will display the known list of packages available for
Babel. An optional ``--ver`` parameter can be specified to tell Babel to
query remote git repositories for the list of versions of the packages and to
then print the versions. Please note however that this can be slow as each
package must be queried separately.

### babel search

If you don't want to go through the whole output of the ``list`` command you
can use the ``search`` command specifying as parameters the package name and/or
tags you want to filter. Babel will look into the known list of available
packages and display only those that match the specified keywords (which can be
substrings). Example:

    $ babel search math
    linagl:
      url:         https://bitbucket.org/BitPuffin/linagl (hg)
      tags:        library, opengl, math, game
      description: OpenGL math library
      license:     CC0
     
    extmath:
      url:         git://github.com/achesak/extmath.nim (git)
      tags:        library, math, trigonometry
      description: Nimrod math library
      license:     MIT

Searches are case insensitive.

An optional ``--ver`` parameter can be specified to tell Babel to
query remote git repositories for the list of versions of the packages and to
then print the versions. Please note however that this can be slow as each
package must be queried separately.

### babel path

The babel ``path`` command will show the absolute path to the installed
packages matching the specified parameters. Since there can be many versions of
the same package installed, the ``path`` command will always show the latest
version. Example:

    $ babel path argument_parser
    /home/user/.babel/pkgs/argument_parser-0.1.2

Under Unix you can use backticks to quickly access the directory of a package,
which can be useful to read the bundled documentation. Example:

    $ pwd
    /usr/local/bin
    $ cd `babel path argument_parser`
    $ less README.md

## Packages

Babel works on git repositories as its primary source of packages. Its list of
packages is stored in a JSON file which is freely accessible in the
[nimrod-code/packages repository](https://github.com/nimrod-code/packages).
This JSON file provides babel with the required Git URL to clone the package
and install it. Installation and build instructions are contained inside a
ini-style file with the ``.babel`` file extension. The babel file shares the
package's name.

## Contribution

If you would like to help, feel free to fork and make any additions you see fit
and then send a pull request. If you are a developer willing to produce new
Babel packages please read the [developers.markdown file](developers.markdown)
for detailed information.

If you have any questions about the project you can ask me directly on github,
ask on the nimrod [forum](http://forum.nimrod-code.org), or ask on Freenode in
the #nimrod channel.

## About

Babel has been written by [Dominik Picheta](http://picheta.me/) with help from
a number of
[contributors](https://github.com/nimrod-code/babel/graphs/contributors).
It is licensed under the BSD license (Look at license.txt for more info).
