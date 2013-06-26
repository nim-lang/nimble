# Babel
Babel is a *beta*-grade *package manager* for the Nimrod programming language.

## Compiling babel
You will need the latest Nimrod compiler from github to compile babel (version 0.9.2 may work).

Compiling it is as simple as ``nimrod c -d:release babel``.

## Babel's folder structure
Babel stores everything that has been installed in ~/.babel on Unix systems and 
in your $home/.babel on Windows. Libraries are stored in $babelDir/pkgs, and
binaries are stored in $babelDir/bin.

## Packages

Babel works on git repositories as its primary source of packages. Its list of
packages is stored in a JSON file which is freely accessible in the
[nimrod-code/packages repository](https://github.com/nimrod-code/packages).
This JSON file provides babel with the required Git URL to clone the package
and install it. Installation and build instructions are contained inside a
ini-style file with the ``.babel`` file extension. The babel file shares
the package's name. 

### Libraries

When babel installs a library it will copy all the files that it downloaded
into ``$babelDir/pkgs/pkgname-ver``. It's up to the package creator to make sure
that the package directory layout is correct, this is so that users of the
package can correctly import the package.

By convention, it is suggested that the layout be as follows. The directory
layout is determined by the nature of your package, that is, whether your
package exposes only one module or multiple modules.

If your package exposes only a single module, then that module should be
present in the root directory (the directory with the babel file) of your git
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

All files and folders in the directory of where the .babel file resides will be
copied as-is, you can however skip some directories or files by setting
the 'SkipDirs' or 'SkipFiles' options in your .babel file.

#### Example library .babel file

```ini
[Package]
name          = "ProjectName"
version       = "0.1.0"
author        = "Your Name"
description   = "Example .babel file."
license       = "MIT"

SkipDirs = "SomeDir" ; ./SomeDir will not be installed
SkipFiles = "file.txt,file2.txt" ; ./{file.txt, file2.txt} will not be installed

[Deps]
Requires: "nimrod >= 0.9.2"
```

All the fields (except ``SkipDirs`` and ``SkipFiles``) under ``[Package]`` are 
required. ``[Deps]`` may be ommitted.

### Binary packages

These are application packages which require building prior to installation.
A package is automatically a binary package as soon as it sets at least one
``bin`` value, like so:

```ini
bin = "main"
```

In this case when ``babel install`` is invoked, babel will build the ``main.nim``
file, copy it into ``$babelDir/pkgs/pkgname-ver/`` and subsequently create a
symlink to the binary in ``$babelDir/bin/``. On Windows a stub .bat file is
created instead.

Dependencies are automatically installed before building.

## Dependencies

Dependencies are specified under the ``[Deps]`` section in a babel file.
The ``requires`` key is used to specify them. For example:

```ini
[Deps]
Requires: "nimrod >= 0.9.2, jester > 0.1 & <= 0.5"
```

Dependency lists support version ranges. These versions may either be a concrete
version like ``0.1``, or they may contain any of the less-than (``<``),
greater-than (``>``), less-than-or-equal-to (``<=``) and greater-than-or-equal-to
(``>=``). Two version ranges may be combined using the ``&`` operator for example:
``> 0.2 & < 1.0`` which will install a package with the version greater than 0.2
and less than 1.0.

## Submitting your package to the package list.
Babel's packages list is stored on github and everyone is encouraged to add
their own packages to it! Take a look at 
[nimrod-code/packages](https://github.com/nimrod-code/packages) to learn more.

## Contribution
If you would like to help, feel free to fork and make any additions you see 
fit and then send a pull request.
If you have any questions about the project you can ask me directly on github, 
ask on the nimrod [forum](http://forum.nimrod-code.org), or ask on Freenode in
the #nimrod channel.

## About
Babel has been written by [Dominik Picheta](http://picheta.me/) and is licensed 
under the BSD license (Look at license.txt for more info).