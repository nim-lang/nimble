# Babel
Babel is a work in progress package manager for Nimrod.

## Babel's folder structure
Babel stores everything that has been installed in ~/.babel on Unix systems and 
in your $home/babel on Windows. Libraries are stored in $babelDir/libs.

## Libraries
Libraries may contain a ``ProjectName.nim`` file, this file will be copied
to ~/.babel/libs/ProjectName.nim allowing anyone to import it by doing
``import ProjectName``, it is recommended to include such a file, however
it's not a requirement.

All public modules should be placed in a ``ProjectName/`` folder. The reason for
this is that the main project file can then import the modules that it needs
and the import filename will work before the installation and after.

Any private modules should be placed, by convention, in
a ``private`` folder inside the ``ProjectName/`` folder, these are modules which
the user of your library should not be importing. All files and folders in
``ProjectName/`` will be copied as-is, you can however specify to skip some
directories or files in your .babel file.

## Example .babel file

```ini
; Example babel file
[Package]
name          = "ProjectName"
version       = "0.1.0"
author        = "Dominik Picheta"
description   = """Example .babel file."""

[Library]
SkipDirs = "SomeDir" ; ./ProjectName/SomeDir will be skipped.
SkipFiles = "file.txt,file2.txt" ; ./ProjectName/{file.txt, file2.txt} will be skipped.
```

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