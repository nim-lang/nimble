# Nimble's folder structure and packages



Nimble stores all installed packages and metadata in `$HOME/.nimble` by default.
Libraries are stored in `$nimbleDir/pkgs2`, and compiled binaries are linked in `$nimbleDir/bin`.
The Nim compiler is aware of Nimble and will automatically find modules so you can `import modulename` and have that working without additional setup.

However, some Nimble packages can provide additional tools or commands.
If you don't add their location (`$nimbleDir/bin`) to your `$PATH` they will not work properly and you won't be able to run them.

If the `nimbledeps` directory exists next to the package `.nimble` file, Nimble will use that directory as `$nimbleDir` and `$HOME/.nimble` will be ignored.
This allows for project local dependencies and isolation from other projects.
The `-l | --localdeps` flag can be used to setup a project in local dependency mode.

Nimble also allows overriding `$nimbleDir` on the command-line with the `--nimbleDir` flag or the `NIMBLE_DIR` environment variable if required.

If the default `$HOME/.nimble` is overridden by one of the above methods, Nimble automatically adds `$nimbleDir/bin` to the PATH for all child processes.
In addition, the `NIMBLE_DIR` environment variable is also set to the specified `$nimbleDir` to inform child Nimble processes invoked in tasks.



## Nim compiler

The Nim compiler cannot read `.nimble` files.
Its knowledge of Nimble is limited to the `nimblePath` feature which allows it to use packages installed in Nimble's package directory when compiling your software.
This means that it cannot resolve dependencies, and it can only use the latest version of a package when compiling.

When Nimble builds your package it executes the Nim compiler.
It resolves the dependencies and feeds the path of each package to the compiler so that it knows precisely which version to use.

This means that you can safely compile using the compiler when developing your software, but you should use Nimble to build the package before publishing it to ensure that the dependencies you specified are correct.



## Compile with `nim` after changing the Nimble directory

The Nim compiler has been pre-configured to look at the default `$HOME/.nimble` directory while compiling, so no extra step is required to use Nimble managed packages.
However, if a custom `$nimbleDir` is in use by one of the methods mentioned earlier, you need to specify the `--nimblePath:PATH` option to Nim.

For example, if your Nimble directory is located at `/some/custom/path/nimble`,
this should work:

``
nim c --nimblePath:/some/custom/path/nimble/pkgs2 main.nim
``

In the case of package local dependencies with `nimbledeps`:

``
nim c --nimblePath:nimbledeps/pkgs2 main.nim
``

Some code editors rely on `nim check` to check for errors under the hood (e.g. VScode), and the editor extension may not allow users to pass custom option to `nim check`, which will cause `nim check` to scream `Error: cannot open file:<the_package>`.
In this case, you will have to use the Nim compiler's configuration file capability.
Simply add the following line to the `nim.cfg` located in any directory listed in the [documentation](https://nim-lang.org/docs/nimc.html#compiler-usage-configuration-files).

``
nimblePath = "/some/custom/path/nimble/pkgs2"
``

For project local dependencies:
``
nimblePath = "$project/nimbledeps/pkgs2"
``
