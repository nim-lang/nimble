# Nimble User Guide


Nimble is the default *package manager* for the [Nim programming
language](https://nim-lang.org).

It can search for Nim packages, install dependencies, create new packages and upload them to the official package list (see [nimble.directory](https://nimble.directory)), and much more.



## Install Nimble

Nimble is bundled with [Nim](https://nim-lang.org).
This means that you should have Nimble installed already, as long as you have
the latest version of Nim installed as well.
Because of this, it is very likely that **you do not need to install Nimble manually**.

In case you still want to install Nimble manually, you can follow [these installation instructions](./install-nimble.md).


## System Requirements

Nimble has some runtime dependencies on external tools, these tools are used to download Nimble packages.
For instance, if a package is hosted on [GitHub](https://github.com), you need to have [git](https://www.git-scm.com) installed and added to your environment ``PATH``.
The same goes for [Mercurial](http://mercurial.selenic.com) repositories.
Nimble packages are typically hosted in Git repositories so you may be able to get away without installing Mercurial.

!!! warning
    Ensure that you have a fairly recent version of `Git` installed.
    Current minimal supported version is `Git 2.22` from 2019-06-07.



## Automatic Nim Version Management

Nimble can automatically download and manage Nim versions for your projects. This feature ensures that each project uses the correct Nim version without manual intervention.

### How It Works

When you run Nimble commands like `build` or `install`:

1. **Nimble checks your project's Nim requirement** specified in the `.nimble` file (e.g., `requires "nim >= 2.0.0"`)
2. **If a compatible Nim is not available**, Nimble automatically downloads a prebuilt binary from [nim-lang.org](https://nim-lang.org)
3. **The downloaded Nim is cached** in `~/.nimble/nim/` and reused for future builds

### Benefits

- **No manual Nim installation required** - Just install Nimble and start building
- **Per-project Nim versions** - Different projects can use different Nim versions
- **Lock file support** - The exact Nim version can be pinned in `nimble.lock`
- **Automatic updates** - When a project requires a newer Nim, it's downloaded automatically

### Using System Nim

Nimble will always try to match your system Nim version against the project's requirements. The `--useSystemNim` flag is used to bypass stricter constraints when you want to force the use of your locally installed Nim:

```sh
nimble build --useSystemNim
```

This is useful when:

- You have a custom Nim build
- You're working offline and already have Nim installed
- You want to test with a specific Nim version not available as a binary


## Getting Started

- If you wish to explore existing Nim packages and install some of them, follow the [using packages guide](./use-packages.md).

- If you would like to create your own Nimble package, the [create Nimble packages guide](./create-packages.md) is for you.

- To learn more about how to use the new workflow with `nimble develop`, follow the [Nimble develop guide](./workflow.md).
