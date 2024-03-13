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



## Getting Started

- If you wish to explore existing Nim packages and install some of them, follow the [using packages guide](./use-packages.md).

- If you would like to create your own Nimble package, the [create Nimble packages guide](./create-packages.md) is for you.

- To learn more about how to use the new workflow with `nimble develop`, follow the [Nimble develop guide](./workflow.md).
