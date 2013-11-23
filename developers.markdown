# Babel for developers

This file contains information mostly meant for developers willing to produce
[Nimrod](http://nimrod-lang.org) modules and submit them to the
[nimrod-code/packages repository](https://github.com/nimrod-code/packages). End
user documentation is provided in the [readme.markdown file](readme.markdown).

## Libraries

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
the ``SkipDirs``, ``SkipFiles`` or ``SkipExt`` options in your .babel file.
Directories and files can also be specified on a *whitelist* basis, if you
specify either of ``InstallDirs``, ``InstallFiles`` or ``InstallExt`` then
babel will **only** install the files specified.

### Example library .babel file

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
required. ``[Deps]`` may be omitted.

## Binary packages

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

Other files will be copied in the same way as they are for library packages.

Binary packages should not install .nim files so you should include
``SkipExt = "nim"`` in your .babel file, unless you intend for your package to
be a binary/library combo which is fine.

Dependencies are automatically installed before building.

# Dependencies

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

# Versions

Versions of cloned packages via git or mercurial are determined through the
repository's *tags*.

When installing a package which needs to be downloaded, after the download is
complete and if the package is distributed through a VCS, babel will check the
cloned repository's tags list. If no tags exist, babel will simply install the
HEAD (or tip in mercurial) of the repository. If tags exist, babel will attempt
to look for tags which resemble versions (e.g. v0.1) and will then find the
latest version out of the available tags, once it does so it will install the
package after checking out the latest version.

# .babel reference

## [Package]

### Required

* ``name`` - The name of the package.
* ``version`` - The *current* version of this package. This should be incremented
  **after** tagging the current version using ``git tag`` or ``hg tag``.
* ``author`` - The name of the author of this package.
* ``description`` - A string describing the package.
* ``license`` - The name of the license in which this package is licensed under.

### Optional

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
  extensions listed in ``InstallExt``, the .babel file and the binary
  (if ``bin`` is specified). Separated by commas.
* ``InstallFiles`` - A list of files which should be exclusively installed,
  this complements ``InstallDirs`` and ``InstallExt``. Only the files listed
  here, directories listed in ``InstallDirs``, files which share the extension
  listed in ``InstallExt``, the .babel file and the binary (if ``bin`` is
  specified) will be installed. Separated by commas.
* ``InstallExt`` - A list of file extensions which should be exclusively
  installed, this complements ``InstallDirs`` and ``InstallFiles``.
  Separated by commas.
* ``srcDir`` - Specifies the directory which contains the .nim source files.
  **Default**: The directory in which the .babel file resides; i.e. root dir of
  package.
* ``bin`` - A list of files which should be built separated by commas with
  no file extension required. This option turns your package into a *binary
  package*, babel will build the files specified and install them appropriately.
* ``backend`` - Specifies the backend which will be used to build the files
  listed in ``bin``. Possible values include: ``c``, ``cc``, ``cpp``, ``objc``,
  ``js``.
  **Default**: c

## [Deps]/[Dependencies]

### Optional

* ``requires`` - Specified a list of package names with an optional version
  range separated by commas.
  **Example**: ``nimrod >= 0.9.2, jester``; with this value your package will
  depend on ``nimrod`` version 0.9.2 or greater and on any version of ``jester``.

# Submitting your package to the package list.

Babel's packages list is stored on github and everyone is encouraged to add
their own packages to it! Take a look at
[nimrod-code/packages](https://github.com/nimrod-code/packages) to learn more.
