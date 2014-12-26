# Babel changelog

## 0.6.0 - 26/12/2014

* Renamed from Babel to Nimble
* Introduces compatibility with Nim v0.10.0+
* Implemented the ``init`` command which generates a .nimble file for new
  projects. (Thank you
  [@singularperturbation](https://github.com/singularperturbation))
* Improved cloning of git repositories.
* Fixes ``path`` command issues (thank you [@gradha](https://github.com/gradha))
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
