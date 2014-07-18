# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

## This module contains additional code from the development version of
## Nimrod's standard library. These procs are required to be able to compile
## against the last stable release 0.9.4. Once 0.9.6 is release these procs
## will disappear.

import json

when not defined(`{}`):
  proc `{}`*(node: PJsonNode, key: string): PJsonNode =
    ## Transverses the node and gets the given value. If any of the
    ## names does not exist, returns nil
    result = node
    if isNil(node): return nil
    result = result[key]

when not defined(`{}=`):
  proc `{}=`*(node: PJsonNode, names: varargs[string], value: PJsonNode) =
    ## Transverses the node and tries to set the value at the given location
    ## to `value` If any of the names are missing, they are added
    var node = node
    for i in 0..(names.len-2):
      if isNil(node[names[i]]):
        node[names[i]] = newJObject()
      node = node[names[i]]
    node[names[names.len-1]] = value
