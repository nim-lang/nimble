# Nimble changelog

## 0.7.4 - 06/06/2016

This release is mainly a bug fix release. The installation problems
introduced by v0.7.0 should now be fixed.

* Fixed symlink install issue
  (Thank you [@yglukhov](https://github.com/yglukhov)).
* Fixed permission issue when installing packages
  (Thank you [@SSPkrolik](https://github.com/SSPkrolik)).
* Work around for issue #204.
  (Thank you [@Jeff-Ciesielski](https://github.com/Jeff-Ciesielski)).
* Fixed FD leak.
  (Thank you [@yglukhov](https://github.com/yglukhov)).
* Implemented the ``--depsOnly`` option for the ``install`` command.
* Various fixes to installation/nimscript support problems introduced by
v0.7.0.

----

Full changelog: https://github.com/nim-lang/nimble/compare/v0.7.2...v0.7.4

## 0.7.2 - 11/02/2016

This is a hotfix release which alleviates problems when building Nimble.

See Issue [#203](https://github.com/nim-lang/nimble/issues/203) for more
information.

## 0.7.0 - 30/12/2015

This is a major release.
Significant changes include NimScript support, configurable package list
URLs, a new ``publish`` command, the removal of the dependency on
OpenSSL, and proxy support. More detailed list of changes follows:

* Fixed ``chcp`` on Windows XP and Windows Vista
  (Thank you [@vegansk](https://github.com/vegansk)).
* Fixed incorrect command line processing
  (Issue [#151](https://github.com/nim-lang/nimble/issues/151))
* Merged ``developers.markdown`` back into ``readme.markdown``
  (Issue [#132](https://github.com/nim-lang/nimble/issues/132))
* Removed advertising clause from license
  (Issue [#153](https://github.com/nim-lang/nimble/issues/153))
* Implemented ``publish`` command
  (Thank you for taking the initiative [@Araq](https://github.com/Araq))
* Implemented NimScript support. Nimble now import a portion of the Nim
  compiler source code for this.
  (Thank you for taking the initiative [@Araq](https://github.com/Araq))
* Fixes incorrect logic for finding the Nim executable
  (Issue [#125](https://github.com/nim-lang/nimble/issues/125)).
* Renamed the ``update`` command to ``refresh``. **The ``update`` command will
  mean something else soon!**
  (Issue [#158](https://github.com/nim-lang/nimble/issues/158))
* Improvements to the ``init`` command.
  (Issue [#96](https://github.com/nim-lang/nimble/issues/96))
* Package names must now officially be valid Nim identifiers. Package's
  with dashes in particular will become invalid in the next version.
  Warnings are shown now but the **next version will show an error**.
  (Issue [#126](https://github.com/nim-lang/nimble/issues/126))
* Added error message when no build targets are present.
  (Issue [#108](https://github.com/nim-lang/nimble/issues/108))
* Implemented configurable package lists. Including fallback URLs
  (Issue [#75](https://github.com/nim-lang/nimble/issues/75)).
* Removed the OpenSSL dependency
  (Commit [ec96ee7](https://github.com/nim-lang/nimble/commit/ec96ee7709f0f8bd323aa1ac5ed4c491c4bf23be))
* Implemented proxy support. This can be configured using the ``http_proxy``/
  ``https_proxy`` environment variables or Nimble's configuration
  (Issue [#86](https://github.com/nim-lang/nimble/issues/86)).
* Fixed issues with reverse dependency storage
  (Issue [#113](https://github.com/nim-lang/nimble/issues/113) and
   [#168](https://github.com/nim-lang/nimble/issues/168)).

----

Full changelog: https://github.com/nim-lang/nimble/compare/v0.6.2...v0.7.0

## 0.6.4 - 30/12/2015

This is a hotfix release fixing compilation with Nim 0.12.0.

See Issue [#180](https://github.com/nim-lang/nimble/issues/180) for more
info.

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
