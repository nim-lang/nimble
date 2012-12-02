# Babel
Babel is a work in progress package manager for Nimrod.

## Babel's folder structure
Babel stores everything that has been installed in ~/.babel on Unix systems and 
in your $home/babel on Windows. Libraries are stored in ~/.babel/libs.

## Libraries
Libraries should contain a ``ProjectName.nim`` file, this file will be copied
to ~/.babel/libs/ProjectName.nim allowing anyone to import it by doing
``import ProjectName``. Any private files should be placed, by convention, in
a ``private`` folder, these are files which the user of your library should not
be using. Every other file and folder will be copied to ~/.babel/libs/ProjectName/.

## Contribution
If you would like to help, feel free to fork and make any additions you see 
fit and then send a pull request.
If you have any questions about the project you can ask me directly on github, 
ask on the nimrod [forum](http://forum.nimrod-code.org), or ask on Freenode in
the #nimrod channel.