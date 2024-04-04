# Nimble package types

When running `nimble init` wizard, you will have three different package types to choose from.
Here are their specifications and differences.



## Libraries

Library packages are likely the most popular form of Nimble packages.
They are meant to be used by other library or binary packages.

When Nimble installs a library, it will copy all of its files into `$nimbleDir/pkgs2/pkgname-ver-checksum`.
It's up to the package creator to make sure that the package directory layout is correct, this is so that users of the package can correctly import the package.

It is suggested that the layout be as follows.
The directory layout is determined by the nature of your package, that is, whether your package exposes only one module or multiple modules.

If your package exposes only a single module, then that module should be
present in the source directory of your Git repository and should be named
whatever your package's name is.
A good example of this is the [jester](https://github.com/dom96/jester) package which exposes the `jester` module.
In this case, the jester package is imported with `import jester`.

If your package exposes multiple modules then the modules should be in a `PackageName` directory.
This will allow for a certain measure of isolation from other packages which expose modules with the same names.
In this case, the package's modules will be imported with `import PackageName/module`.

Here's a simple example multi-module library package called `kool`:

```
.
├── kool
│   ├── useful.nim
│   └── also_useful.nim
└── kool.nimble
```

In regards to modules which you do **not** wish to be exposed.
You should place them in a `PackageName/private` directory.
Your modules may then import these private modules with `import PackageName/private/module`.
This directory structure may be enforced in the future.

All files and folders in the directory where the `.nimble`` file resides will be copied as-is.
You can however skip some directories or files by setting the `skipDirs`, `skipFiles` or `skipExt` options in your .nimble file.
Directories and files can also be specified on a *whitelist* basis.
If you specify either of `installDirs`, `installFiles` or `installExt`, then
Nimble will *only* install the files specified.




## Binary packages

These are application packages which require building prior to installation.
A package is automatically a binary package as soon as it sets at least one `bin` value, like so:

```ini
bin = @["main"]
```

In this case when `nimble install` is invoked, Nimble will build the `main.nim`
file, copy it into `$nimbleDir/pkgs2/pkgname-ver-checksum/` and subsequently
create a symlink to the binary in `$nimbleDir/bin/`.
On Windows, a stub `.cmd` file is created instead.

The binary can be named differently than the source file with the `namedBin`
table:

```nim
namedBin["main"] = "mymain"
namedBin = {"main": "mymain", "main2": "other-main"}.toTable()
```

Note that `namedBin` entries override duplicates in `bin`.

Dependencies are automatically installed before building.
It's a good idea to test that the dependencies you specified are correct by running `nimble build` or `nimble install` in the directory of your package.




## Hybrids

Binary packages will not install .nim files so include `installExt = @["nim"]`
in your `.nimble` file if you intend for your package to be a hybrid binary/library
combo.

Historically, binaries that shared the name of a `pkgname` directory that contains additional `.nim` files required workarounds.
This is now handled behind the scenes by appending an `.out` extension to the binary and is transparent to commands like `nimble run` or symlinks which can still refer to the original binary name.
