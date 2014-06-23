# Babel changelog

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
