# `.nimble` file reference



## [Package]

### Required

* `name` - The name of the package. *(This is not required in the new NimScript format)*
* `version` - The *current* version of this package. This should be incremented
  *before* tagging the current version using `git tag` or `hg tag`.
* `author` - The name of the author of this package.
* `description` - A string describing the package.
* `license` - The name of the license under which this package is licensed.



### Optional

* `skipDirs` - A list of directory names which should be skipped during
  installation, separated by commas.
* `skipFiles` - A list of file names which should be skipped during
  installation, separated by commas.
* `skipExt` - A list of file extensions which should be skipped during
  installation, the extensions should be specified without a leading `.`, and
  should be separated by commas.
* `installDirs` - A list of directories which should exclusively be installed.
  If this option is specified nothing else will be installed except the dirs
  listed here, the files listed in `installFiles`, the files which share the
  extensions listed in `installExt`, the `.nimble` file, and, if `bin` or `namedBin` is specified, the binary.
  Separated by commas.
* `installFiles` - A list of files which should be exclusively installed.
  This complements `installDirs` and `installExt`. Only the files listed
  here, directories listed in `installDirs`, files which share the extension
  listed in `installExt`, the `.nimble` file and the binary (if `bin` or `namedBin`
  is specified) will be installed. Separated by commas.
* `installExt` - A list of file extensions which should be exclusively
  installed. This complements `installDirs` and `installFiles`.
  Separated by commas.
* `srcDir` - Specifies the directory which contains the `.nim` source files.
  **Default**: The directory in which the `.nimble` file resides; i.e. root dir of
  the package.
* `binDir` - Specifies the directory where `nimble build` will output
  binaries.
  **Default**: The directory in which the `.nimble` file resides; i.e.
  root dir of the package.
* `bin` - A list of files which should be built separated by commas with
  no file extension required. This option turns your package into a *binary package*.
  Nimble will build the files specified and install them appropriately.
* `namedBin` - A list of `name:value` files which should be built with specified
  name, no file extension required. This option turns your package into a
  *binary package*. Nimble will build the files specified and install them appropriately.
  `namedBin` entries override duplicates in `bin`.
* `backend` - Specifies the backend which will be used to build the files
  listed in `bin`. Possible values include: `c`, `cc`, `cpp`, `objc`,
  `js`.
* ``paths`` - A list of relative paths that will be expanded on `nimble.paths` and the search paths options to the compiler.
* ``entryPoints`` - A list of relative paths to nim files that will be used by the `nimlangserver` as project entry points. Useful for test files like `tall.nim`
  **Default**: `c`.






## [Deps]/[Dependencies]

### Optional

* `requires` - Specifies a list of package names with an optional version
  range separated by commas.
  **Example**: `nim >= 0.10.0, jester`; with this value your package will
  depend on `nim` version 0.10.0 or greater and on any version of `jester`.


