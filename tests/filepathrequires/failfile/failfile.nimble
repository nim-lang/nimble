# Package

version       = "0.1.0"
author        = "jmgomez"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
bin           = @["failfile"]


# Dependencies
#This should only work inside the graph. 
requires "file://../depfile"