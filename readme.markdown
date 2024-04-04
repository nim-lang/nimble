# Nimble


Nimble is the default *package manager* for the
[Nim programming language](https://nim-lang.org).




## Documentation

Interested in how to use Nimble? See the
[Nimble Guide](https://nim-lang.github.io/nimble/index.html),
where you can learn:
- [How to install existing packages](https://nim-lang.github.io/nimble/use-packages.html)
- [How to create a Nimble package](https://nim-lang.github.io/nimble/create-packages.html)
- [How to use `nimble develop` workflow](https://nim-lang.github.io/nimble/workflow.html)


This documentation is for the latest commit of Nimble.
Nim releases ship with a specific version of Nimble and may
not contain all the features and fixes described here.
`nimble -v` will display the version of Nimble in use.

The Nimble changelog can be found
[here](https://github.com/nim-lang/nimble/blob/master/changelog.markdown).





## Repository information

This repository has two main branches: `master` and `stable`.

The `master` branch is...

* default
* bleeding edge
* tested to compile with a pinned (close to HEAD) commit of Nim

The `stable` branch is...

* installed by `koch tools`/`koch nimble`
* relatively stable
* should compile with Nim HEAD as well as the latest Nim version

Note: The travis build only tests whether Nimble works with the latest Nim
version.

A new Nim release (via `koch xz`) will always bundle the `stable` branch.





## Contribution

If you would like to help, feel free to fork and make any additions you see fit
and then send a pull request.

If you have any questions about the project, you can ask me directly on GitHub,
ask on the Nim [forum](https://forum.nim-lang.org), or ask on Freenode in
the #nim channel.





## About

Nimble has been written by [Dominik Picheta](https://picheta.me/) with help from
a number of
[contributors](https://github.com/nim-lang/nimble/graphs/contributors).
It is licensed under the 3-clause BSD license, see [license.txt](license.txt)
for more information.
