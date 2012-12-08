# Babel
Babel is a work in progress *package manager* for Nimrod.

## Compiling babel
You will need the latest Nimrod compiler from github to compile babel.

Compiling it is as simple as ``nimrod c babel``.

## Babel's folder structure
Babel stores everything that has been installed in ~/babel on Unix systems and 
in your $home/babel on Windows. Libraries are stored in $babelDir/libs.

## Libraries

By convention, if you have a single file with the same filename as your package
name, then you can include it in the same directory as the .babel file.
However, if you have other public modules whose names are quite common, 
they should be included in a separate directory by the name of "PackageName", so
as to not pollute the namespace. This will mean that your main file can be
imported by simply writing ``import PackageName`` and all other public modules
can be imported by writing ``import PackageName/module``. This structure can be
seen being used by [jester](https://github.com/dom96/jester).

All private modules should be placed, by convention, in
a ``private`` folder, these are modules which
the user of your library should not be importing.

All files and folders in the directory of where the .babel file resides will be
copied as-is, you can however skip some directories or files in your by setting
the 'SkipDirs' or 'SkipFiles' options in your .babel file.

## Example .babel file

```ini
; Example babel file
[Package]
name          = "ProjectName"
version       = "0.1.0"
author        = "Dominik Picheta"
description   = """Example .babel file."""
license       = "MIT"

SkipDirs = "SomeDir" ; ./ProjectName/SomeDir will be skipped.
SkipFiles = "file.txt,file2.txt" ; ./ProjectName/{file.txt, file2.txt} will be skipped.

[Deps]
Requires: "nimrod >= 0.8.0"
```

All the fields (except ``SkipDirs`` and ``SkipFiles``) under ``[Package]`` are 
required.

## Submitting your package to the package list.
Babel's packages list is stored on github and everyone is encouraged to add
their own packages to it! Take a look at 
[nimrod-code/packages](https://github.com/nimrod-code/packages) to learn more.

## Contribution
If you would like to help, feel free to fork and make any additions you see 
fit and then send a pull request.
If you have any questions about the project you can ask me directly on github, 
ask on the nimrod [forum](http://forum.nimrod-code.org), or ask on Freenode in
the #nimrod channel.

## About
Babel has been written by [Dominik Picheta](http://picheta.me/) and is licensed 
under the BSD license (Look at license.txt for more info).