# Babel changelog

## 0.6.2 - 19/06/2015

* Added ``binDir`` option to specify where the build output should be placed
  (Thank you [@minciue](https://github.com/minciue)).
* Fixed deprecated code (Thank you [@lou15b](https://github.com/lou15b)).
* Fixes to old ``.babel`` folder handling
  (Thank you [@ClementJnc](https://github.com/ClementJnc)).
* Added ability to list only the installed packages via
  ``nimble list --installed`` (Thank you
  [@hiteshjasani](https://github.com/hiteshjasani).
* Fixes compilation with Nim v0.11.2 (Thank you
  [@JCavallo](https://github.com/JCavallo)).
* Implements the ``--nimbleDir`` option (Thank you
  [@ClementJnc](https://github.com/ClementJnc)).
* [Fixes](https://github.com/nim-lang/nimble/issues/128) ``nimble uninstall``
  not giving an error when no package name is
  specified (Thank you [@dom96](https://github.com/dom96)).
* [When](https://github.com/nim-lang/nimble/issues/139) installing and building
  a tagged version of a package fails, Nimble will
  now attempt to install and build the ``#head`` of the repo
  (Thank you [@dom96](https://github.com/dom96)).
* [Fixed](https://github.com/nim-lang/nimble/commit/1234cdce13c1f1b25da7980099cffd7f39b54326)
  cloning of git repositories with non-standard default branches
  (Thank you [@dom96](https://github.com/dom96)).

----

Full changelog: https://github.com/nim-lang/nimble/compare/v0.6...v0.6.2

## 0.6.0 - 26/12/2014

* Renamed from Babel to Nimble
* Introduces compatibility with Nim v0.10.0+
* Implemented the ``init`` command which generates a .nimble file for new
  projects. (Thank you
  [@singularperturbation](https://github.com/singularperturbation))
* Improved cloning of git repositories.
  (Thank you [@gradha](https://github.com/gradha))
* Fixes ``path`` command issues (Thank you [@gradha](https://github.com/gradha))
* Fixes problems with symlinking when there is a space in the path.
  (Thank you [@philip-wernersbach](https://github.com/philip-wernersbach))
* The code page will now be changed when executing Nimble binary packages.
  This adds support for Unicode in cmd.exe (#54).
* ``.cmd`` files are now used in place of ``.bat`` files. Shell files for
  Cygwin/Git bash are also now created.

## 0.4.0 - 24/06/2014

* Introduced the ability to delete packages.
* When installing packages, a list of files which have been copied is stored
  in the babelmeta.json file.
* When overwriting an already installed package babel will no longer delete
  the whole directory but only the files which it installed.
* Versions are now specified on the command line after the '@' character when
  installing and uninstalling packages. For example: ``babel install foobar@0.1``
  and ``babel install foobar@#head``.
* The babel package installation directory can now be changed in the new
  config.
* Fixes a number of issues.
