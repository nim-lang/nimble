* better config options, add config file
* commit hashes as versions for dependencies
  * Perhaps add some easy way to distinguish between real versions and commit
    maybe use ``@``; ``@c645asd``.
* Stricter directory layouts.
* Stricter version allowance -- disallow any letters in version numbers.

* A way to install specific versions of a package.
* more package download methods
  * Allow for proper versions of packages to download. Reuse 'version' field
    in packages.json.
* Install only .nim files when installing library packages?
* Force disable --babelPath when building binary packages?