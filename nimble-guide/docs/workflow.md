# Nimble develop workflow

This guide assumes you are already familiar with [creating a new Nimble package](./create-packages.md).

Here you will learn how to use `nimble develop` to update the dependencies of your package.
First we will list and explain all commands connected to this workflow, and at the bottom of the page you'll see the example of using them in praxis.







## `nimble setup`

The `nimble setup` command creates a `nimble.paths` file containing file system paths to the dependencies.
It also includes the paths file in the `config.nims` file (by creating it if it does not already exist) to make them available for the compiler.

The command also adds `nimble.develop` and `nimble.paths` files to the `.gitignore` file.

!!! warning
    `nimble.paths` file is user-specific and must *not* be committed.





## `nimble lock`

The `nimble lock` command will generate or update a package lock file named `nimble.lock`.
This file is used for pinning the exact versions of the dependencies of the package. 
The file is intended to be committed and used by other developers to ensure that exactly the same version of the dependencies is used by all developers.

The lock files have the structure as in the following example:

```json
{
  "version": 2,
  "packages": {
     ...
     "chronos": {
      "version": "3.0.2",
      "vcsRevision": "aab1e30a726bb47c5d3f4a75a826981836cde9e2",
      "url": "https://github.com/status-im/nim-chronos",
      "downloadMethod": "git",
      "dependencies": [
        "stew",
        "bearssl",
        "httputils",
        "unittest2"
      ],
      "checksums": {
        "sha1": "a1cdaa77995f2d1381e8f9dc129594f2fa2ee07f"
      }
    },
    ...
  }
}
```

* `version` - JSON schema version.
* `packages` - JSON object containing JSON objects for all dependencies,
* `chronos` - Nested JSON object keys are the names of the dependencies
packages.
* `version` - The version of the dependency.
* `vcsRevision` - The revision at which the dependency is locked.
* `url` - The URL of the repository of the package.
* `downloadMethod` - `git` or `hg` according to the type of the repository at
`url`.
* `dependencies` - The direct dependencies of the package.
  Used for writing the reverse dependencies of the package in the `nimbledata.json` file.
  Those packages' names also must be in the lock file.
* `checksums` - A JSON compound object containing different checksums used for verifying that a downloaded package is exactly the same as the pinned in the lock file package.
  Currently, only `sha1` checksums are supported.
* `sha1` - The *sha1* checksum of the package files.

If a lock file `nimble.lock` exists, then on performing all Nimble commands which require searching for dependencies and downloading them in the case they are missing (like `build`, `install`, `develop`), it is read and its content is used to download the same version of the project dependencies by using the URL, download method and VCS revision written in it.

The checksum of the downloaded package is compared against the one written in the lock file.
In the case the two checksums are not equal then it will be printed error message and the operation will be aborted.
Reverse dependencies are added for installed locked dependencies just like for any other package being locally installed.





## `nimble develop`

The develop command is used for putting packages in a development mode.
When executed with a list of packages, it clones their repositories.
If it is executed in a package directory, it adds cloned packages to the special `nimble.develop` file.
This is a special file which is used for holding the paths to development mode dependencies of the current directory package.
It has the following structure:

```json
{
    "version": 1,
    "includes": [],
    "dependencies": []
}
```

* `version` - JSON schema version
* `includes` - JSON array of paths to included files.
* `dependencies` - JSON array of paths to Nimble packages directories.

The format for included develop files is the same as the project's develop file.

Develop files validation rules:

* The included develop files must be valid.
* The packages listed in the `dependencies` section and in the included develop files are required to be valid Nimble packages, but they are not required to be valid dependencies of the current project.
  In the latter case, they are simply ignored.
* The develop files of the develop mode dependencies of a package are being followed and processed recursively.
  Finally, only one common set of develop mode dependencies is created.
* In the final set of develop mode dependencies, it is not allowed to have more than one package with the same name but with different file system paths.

Just as with the `install` command, a package URL may also be specified instead of a name.

If present, the validity of the package's develop file is added to the requirements for validity of the package which is determined by `nimble check` command.

The `develop` command has a list of options:

* `-p, --path path` - Specifies the path whether the packages should be cloned.
* `-c, --create [path]` - Creates an empty develop file with the name `nimble.develop` in the current directory, or, if a path is present, to the given directory with a given name.
* `-a, --add path` - Adds the package at the given path to the `nimble.develop` file.
* `-r, --removePath path` - Removes the package at the given path from the `nimble.develop` file.
* `-n, --removeName path` - Removed the package with the given name from the `nimble.develop` file.
* `-i, --include file` - Includes a develop file into the current directory's one.
* `-e, --exclude file` - Excludes a develop file from the current directory's one.
* `--withDependencies` - Clones for develop also the dependencies of the packages for which the develop command is executed.
* `--developFile` - Changes the name of the develop file which to be manipulated.
  It is useful for creating a free develop file which is not associated with any project intended for inclusion in some other develop file.
* `-g, --global` - Creates an old style link file in the special `links` directory.
  It is read by Nim to be able to use global develop mode packages.
  Nimble uses it as a global develop file if a local one does not exist.

The options for manipulation of the develop files could be given only when executing `develop` command from some package's directory, unless `--developFile` option with a name of develop file is explicitly given.

Because the develop files are user-specific and they contain local file system
paths they must not be committed.
(Running `nimble setup` takes care of this by adding `nimble.develop` to the `.gitignore` file.)



### `.nimble-link`

These files are created by Nimble when using the `develop` command.
They are very simple and contain two lines.

* The first line: Always a path to the `.nimble` file.

* The second line: Always a path to the Nimble package's source code.
  Usually `$pkgDir/src`, depending on what `srcDir` is set to.

The paths written by Nimble are always absolute.
But Nimble (and the Nim compiler) also supports relative paths, which will be read relative to the `.nimble-link` file.





## `nimble sync`

The `nimble sync` command will synchronize develop mode dependencies with the content of the lock file.
If the revision specified in the lock file is not found locally, it tries to fetch it from the configured remotes.
If it is present on multiple branches, it tries to stay on the current one, and if can't, it prefers
local branches rather than remote-tracking ones.
If found on more than one branch, it gives the user a choice whether to switch.

Sync operation will also download non-develop mode dependencies versions described in the lock file if they are not already present in the Nimble cache.

If the `-l, --listOnly` option is given then the command only lists development mode dependencies whose working copies are out of sync, without actually syncing them and without downloading missing non-develop mode dependencies.







## Example

Starting from a `myPackage` project we used as an example in [creating Nimble packages guide](./create-packages.md), first we will add some dependencies to the `myPackage.nimble` file:

```nim
...

# Dependencies

requires "nim >= 2.0.0"
requires "nimibook == 0.3.1"
requires "itertools == 0.3.0"

...
```

Now we run `nimble setup` to see if we already have all needed dependencies or if there is something that needs to be downloaded.
This command also creates/updates `nimble.paths` and `config.nims` files.

```sh
$ nimble setup
  Verifying dependencies for myPackage@0.1.0
     Info:  Dependency on nimibook@0.3.1 already satisfied
  Verifying dependencies for nimibook@0.3.1
     Info:  Dependency on nimib@>= 0.3.7 already satisfied
  Verifying dependencies for nimib@0.3.10
     Info:  Dependency on fusion@>= 1.2 already satisfied
  Verifying dependencies for fusion@1.2
     Info:  Dependency on markdown@>= 0.8.1 already satisfied
  Verifying dependencies for markdown@0.8.7
     Info:  Dependency on mustache@>= 0.2.1 already satisfied
  Verifying dependencies for mustache@0.4.3
     Info:  Dependency on parsetoml@>= 0.7.0 already satisfied
  Verifying dependencies for parsetoml@0.7.1
     Info:  Dependency on jsony@>= 1.1.5 already satisfied
  Verifying dependencies for jsony@1.1.5
     Info:  Dependency on jsony@>= 1.1.5 already satisfied
  Verifying dependencies for jsony@1.1.5
 Installing itertools@0.3.0
Downloading https://github.com/narimiran/itertools using git
  Verifying dependencies for itertools@0.3.0
 Installing itertools@0.3.0
  Success:  itertools installed successfully.
     Info:  "nimble.paths" is generated.
     Info:  "config.nims" is set up.
```

With all the dependencies installed, we can now create a lock file by running `nimble lock`:

```sh
$ nimble lock
     Info:  Generating the lock file...
  Verifying dependencies for myPackage@0.1.0
     Info:  Dependency on nimibook@0.3.1 already satisfied
  Verifying dependencies for nimibook@0.3.1
     Info:  Dependency on nimib@>= 0.3.7 already satisfied
  Verifying dependencies for nimib@0.3.10
     Info:  Dependency on fusion@>= 1.2 already satisfied
  Verifying dependencies for fusion@1.2
     Info:  Dependency on markdown@>= 0.8.1 already satisfied
  Verifying dependencies for markdown@0.8.7
     Info:  Dependency on mustache@>= 0.2.1 already satisfied
  Verifying dependencies for mustache@0.4.3
     Info:  Dependency on parsetoml@>= 0.7.0 already satisfied
  Verifying dependencies for parsetoml@0.7.1
     Info:  Dependency on jsony@>= 1.1.5 already satisfied
  Verifying dependencies for jsony@1.1.5
     Info:  Dependency on jsony@>= 1.1.5 already satisfied
  Verifying dependencies for jsony@1.1.5
     Info:  Dependency on itertools@0.3.0 already satisfied
  Verifying dependencies for itertools@0.3.0
  Success:  The lock file is generated.
```

We can run `nimble check` to verify everything is working properly:

```sh
$ nimble check
  Success:  The package "myPackage" is valid.
```

If you don't need to update and/or modify your dependencies, your job is done.
You can commit the `nimble.lock` file to make sure other developers, when they work on your package, use the exact same dependencies as you.

On the other hand, if you want to fix a bug in a dependency which manifests in your own package, or you want to see if an updated version of some dependency will still work with your package, the `nimble develop` command will come handy.

For our example, let's say we want to update the `itertools` dependency from version `0.3.0` to version `0.4.0`.
We will put `itertools` in the develop mode, which will clone its git repo to a subdirectory of our package:

```sh
$ nimble develop itertools
Downloading https://github.com/narimiran/itertools using git
  Verifying dependencies for itertools@0.4.0
  Success:  "itertools" set up in develop mode successfully to "/home/user/myPackage/itertools".
  Success:  The package "itertools@0.4.0" at path "/home/user/myPackage/itertools"
            is added to the develop file "nimble.develop".
     Info:  "nimble.paths" is updated.
```

If you check the contents of `nimble.paths`, you will notice that the path for `itertools` is no more in `~/.nimble/pkgs2` directory (where the version 0.3.0 is), but it has the following value:

```sh
...
--path:"/home/user/myPackage/itertools/src"
...
```

We can now run our tests, which will use the updated version of `itertools` to see if everything still works as expected.

Running `nimble check` now will correctly warn us that our working copy and the lock file are not synchronized:

```sh
$ nimble check
    Error:  Some of package's develop mode dependencies are invalid.
        ... Package "itertools" at "/home/user/myPackage/itertools" has not synced working copy..
     Hint:  You have to call `nimble sync` to synchronize your develop mode dependencies working copies with the latest lock file.
   Failure: Validation failed.
```

There are two paths we can take to synchronize them.
One is, as it says in the hint above, to put the development version at the state written in the lock file (in our case, to checkout version 0.3.0), by running `nimble sync`.
The other option is to update the lock file (to use version 0.4.0) by running `nimble lock`.

If we run `nimble lock` at this point, we will get an error, reminding us that in `myPackage.nimble` we still have `requires "itertools == 0.3.0"`, which we need to manually update to `0.4.0`.
After we change the version number in the `.nimble` file, we can successfully run `nimble lock`:

```sh
$ nimble lock
     Info:  Updating the lock file...
  Verifying dependencies for myPackage@0.1.0
     Info:  Dependency on nimibook@0.3.1 already satisfied
  Verifying dependencies for nimibook@0.3.1
     Info:  Dependency on nimib@>= 0.3.7 already satisfied
  Verifying dependencies for nimib@0.3.10
     Info:  Dependency on fusion@>= 1.2 already satisfied
  Verifying dependencies for fusion@1.2
     Info:  Dependency on markdown@>= 0.8.1 already satisfied
  Verifying dependencies for markdown@0.8.7
     Info:  Dependency on mustache@>= 0.2.1 already satisfied
  Verifying dependencies for mustache@0.4.3
     Info:  Dependency on parsetoml@>= 0.7.0 already satisfied
  Verifying dependencies for parsetoml@0.7.1
     Info:  Dependency on jsony@>= 1.1.5 already satisfied
  Verifying dependencies for jsony@1.1.5
     Info:  Dependency on jsony@>= 1.1.5 already satisfied
  Verifying dependencies for jsony@1.1.5
     Info:  Dependency on itertools@0.4.0 already satisfied
  Verifying dependencies for itertools@0.4.0
  Success:  The lock file is updated.
```

Here are the changes in the `nimble.lock` file:

```diff
--- a/nimble.lock
+++ b/nimble.lock
@@ -12,13 +12,13 @@
       }
     },
     "itertools": {
-      "version": "0.3.0",
-      "vcsRevision": "b0f6bb887c39bc7730f45abb72f7e9edd4714a66",
+      "version": "0.4.0",
+      "vcsRevision": "06c4de8b6b124368be269b00ecd0b34a3731739f",
       "url": "https://github.com/narimiran/itertools",
       "downloadMethod": "git",
       "dependencies": [],
       "checksums": {
-        "sha1": "adaadfebd990a33d5e25df2fd0ce45a762af1003"
+        "sha1": "e98b828dbee752fb6f22cb3fe9fd00c13a2514f5"
       }
     },
     "jsony": {
```

Running `nimble check` confirms everything is synchronized:

```sh
$ nimble check
  Success:  The package "myPackage" is valid.
```

We can now commit the changes in `myPackage.nimble` and `nimble.lock` files, so that our package uses updated dependencies and other developers are able to use the exact versions as we are running locally.

If you are that "other developer" who is also working on the same package with your own develop-mode dependencies, and the package is updated by your colleague in the way described above, after you run `git pull` you will also need to run `nimble sync` to get synchronize the new version of the lockfile and your local dependencies.
