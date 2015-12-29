# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import parsecfg, streams, strutils, os, tables, Uri

import tools, version, nimbletypes

type
  Config* = object
    nimbleDir*: string
    chcp*: bool # Whether to change the code page in .cmd files on Win.
    packageLists*: Table[string, PackageList] ## URLs to packages.json files
    cloneUsingHttps*: bool # Whether to replace git:// for https://
    httpProxy*: Uri # Proxy for package list downloads.

  PackageList* = object
    name*: string
    urls*: seq[string]

proc initConfig(): Config =
  if getNimrodVersion() > newVersion("0.9.6"):
    result.nimbleDir = getHomeDir() / ".nimble"
  else:
    result.nimbleDir = getHomeDir() / ".babel"

  result.httpProxy = initUri()

  result.chcp = true
  result.cloneUsingHttps = true

  result.packageLists = initTable[string, PackageList]()
  let defaultPkgList = PackageList(name: "Official", urls: @[
    "http://irclogs.nim-lang.org/packages.json",
    "http://nim-lang.org/nimble/packages.json",
    "https://github.com/nim-lang/packages/raw/master/packages.json"
  ])
  result.packageLists["official"] = defaultPkgList

proc initPackageList(): PackageList =
  result.name = ""
  result.urls = @[]

proc addCurrentPkgList(config: var Config, currentPackageList: PackageList) =
  if currentPackageList.name.len > 0:
    config.packageLists[currentPackageList.name.normalize] = currentPackageList

proc parseConfig*(): Config =
  result = initConfig()
  var confFile = getConfigDir() / "nimble" / "nimble.ini"

  var f = newFileStream(confFile, fmRead)
  if f == nil:
    # Try the old deprecated babel.ini
    confFile = getConfigDir() / "babel" / "babel.ini"
    f = newFileStream(confFile, fmRead)
    if f != nil:
      echo("[Warning] Using deprecated config file at ", confFile)
  
  if f != nil:
    echo("Reading from config file at ", confFile)
    var p: CfgParser
    open(p, f, confFile)
    var currentSection = ""
    var currentPackageList = initPackageList()
    while true:
      var e = next(p)
      case e.kind
      of cfgEof:
        addCurrentPkgList(result, currentPackageList)
        break
      of cfgSectionStart:
        addCurrentPkgList(result, currentPackageList)
        currentSection = e.section
        case currentSection.normalize
        of "packagelist":
          currentPackageList = initPackageList()
        else:
          raise newException(NimbleError, "Unable to parse config file:" &
                             " Unknown section: " & e.key)
      of cfgKeyValuePair, cfgOption:
        case e.key.normalize
        of "nimbledir":
          # Ensure we don't restore the deprecated nimble dir.
          if e.value != getHomeDir() / ".babel":
            result.nimbleDir = e.value
        of "chcp":
          result.chcp = parseBool(e.value)
        of "cloneusinghttps":
          result.cloneUsingHttps = parseBool(e.value)
        of "httpproxy":
          result.httpProxy = parseUri(e.value)
        of "name":
          case currentSection.normalize
          of "packagelist":
            currentPackageList.name = e.value
          else: assert false
        of "url":
          case currentSection.normalize
          of "packagelist":
            currentPackageList.urls.add(e.value)
          else: assert false
        else:
          raise newException(NimbleError, "Unable to parse config file:" &
                                     " Unknown key: " & e.key)
      of cfgError:
        raise newException(NimbleError, "Unable to parse config file: " & e.msg)
    close(p)
