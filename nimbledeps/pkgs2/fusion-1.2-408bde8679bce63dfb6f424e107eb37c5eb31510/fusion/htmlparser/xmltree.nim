#
#
#            Nim's Runtime Library
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## A simple XML tree generator.
##
## .. code-block::
##   import xmltree
##
##   var g = newElement("myTag")
##   g.add newText("some text")
##   g.add newComment("this is comment")
##
##   var h = newElement("secondTag")
##   h.add newEntity("some entity")
##
##   let att = {"key1": "first value", "key2": "second value"}.toXmlAttributes
##   let k = newXmlTree("treeTag", [g, h], att)
##
##   echo k
##   # <treeTag key2="second value" key1="first value">
##   #   <myTag>some text<!-- this is comment --></myTag>
##   #   <secondTag>&some entity;</secondTag>
##   # </treeTag>
##
##
## **See also:**
## * `xmlparser module <xmlparser.html>`_ for high-level XML parsing
## * `parsexml module <parsexml.html>`_ for low-level XML parsing
## * `htmlgen module <htmlgen.html>`_ for html code generator

import macros, strtabs, strutils
include "system/inclrtl"

type
  XmlNode* = ref XmlNodeObj ## An XML tree consisting of XML nodes.
    ##
    ## Use `newXmlTree proc <#newXmlTree,string,openArray[XmlNode],XmlAttributes>`_
    ## for creating a new tree.

  XmlNodeKind* = enum ## Different kinds of XML nodes.
    xnText,           ## a text element
    xnVerbatimText,   ##
    xnElement,        ## an element with 0 or more children
    xnCData,          ## a CDATA node
    xnEntity,         ## an entity (like ``&thing;``)
    xnComment         ## an XML comment

  XmlAttributes* = StringTableRef ## An alias for a string to string mapping.
    ##
    ## Use `toXmlAttributes proc <#toXmlAttributes,varargs[tuple[string,string]]>`_
    ## to create `XmlAttributes`.

  XmlNodeObj {.acyclic.} = object
    case k: XmlNodeKind # private, use the kind() proc to read this field.
    of xnText, xnVerbatimText, xnComment, xnCData, xnEntity:
      fText: string
    of xnElement:
      fTag: string
      s: seq[XmlNode]
      fAttr: XmlAttributes
    fClientData: int    ## for other clients

const
  xmlHeader* = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n"
    ## Header to use for complete XML output.
  singleTags = ["area", "base", "basefont",
    "br", "col","embed", "frame", "hr", "img",
    "input","source","track",
    "isindex", # obsolete HTML 4.01
    "link", "meta", "param", "wbr",
    "command", # obsolete
    "keygen", # obsolete
    ]

proc newXmlNode(kind: XmlNodeKind): XmlNode =
  ## Creates a new ``XmlNode``.
  result = XmlNode(k: kind)

proc newElement*(tag: string): XmlNode =
  ## Creates a new ``XmlNode`` of kind ``xnElement`` with the given `tag`.
  ##
  ## See also:
  ## * `newXmlTree proc <#newXmlTree,string,openArray[XmlNode],XmlAttributes>`_
  ## * [<> macro](#<>.m,untyped)
  runnableExamples:
    var a = newElement("firstTag")
    a.add newElement("childTag")
    assert a.kind == xnElement
    assert $a == """<firstTag>
  <childTag>
  </childTag>
</firstTag>"""

  result = newXmlNode(xnElement)
  result.fTag = tag
  result.s = @[]
  # init attributes lazily to save memory

proc newText*(text: string): XmlNode =
  ## Creates a new ``XmlNode`` of kind ``xnText`` with the text `text`.
  runnableExamples:
    var b = newText("my text")
    assert b.kind == xnText
    assert $b == "my text"

  result = newXmlNode(xnText)
  result.fText = text

proc newVerbatimText*(text: string): XmlNode =
  ## Creates a new ``XmlNode`` of kind ``xnVerbatimText`` with the text `text`.
  ## **Since**: Version 1.3.
  result = newXmlNode(xnVerbatimText)
  result.fText = text

proc newComment*(comment: string): XmlNode =
  ## Creates a new ``XmlNode`` of kind ``xnComment`` with the text `comment`.
  runnableExamples:
    var c = newComment("my comment")
    assert c.kind == xnComment
    assert $c == "<!-- my comment -->"

  result = newXmlNode(xnComment)
  result.fText = comment

proc newCData*(cdata: string): XmlNode =
  ## Creates a new ``XmlNode`` of kind ``xnCData`` with the text `cdata`.
  runnableExamples:
    var d = newCData("my cdata")
    assert d.kind == xnCData
    assert $d == "<![CDATA[my cdata]]>"

  result = newXmlNode(xnCData)
  result.fText = cdata

proc newEntity*(entity: string): XmlNode =
  ## Creates a new ``XmlNode`` of kind ``xnEntity`` with the text `entity`.
  runnableExamples:
    var e = newEntity("my entity")
    assert e.kind == xnEntity
    assert $e == "&my entity;"

  result = newXmlNode(xnEntity)
  result.fText = entity

proc newXmlTree*(tag: string, children: openArray[XmlNode],
                 attributes: XmlAttributes = nil): XmlNode =
  ## Creates a new XML tree with `tag`, `children` and `attributes`.
  ##
  ## See also:
  ## * `newElement proc <#newElement,string>`_
  ## * [<> macro](#<>.m,untyped)
  ##
  ## .. code-block::
  ##   var g = newElement("myTag")
  ##   g.add newText("some text")
  ##   g.add newComment("this is comment")
  ##   var h = newElement("secondTag")
  ##   h.add newEntity("some entity")
  ##   let att = {"key1": "first value", "key2": "second value"}.toXmlAttributes
  ##   let k = newXmlTree("treeTag", [g, h], att)
  ##
  ##   echo k
  ##   ## <treeTag key2="second value" key1="first value">
  ##   ##   <myTag>some text<!-- this is comment --></myTag>
  ##   ##   <secondTag>&some entity;</secondTag>
  ##   ## </treeTag>

  result = newXmlNode(xnElement)
  result.fTag = tag
  newSeq(result.s, children.len)
  for i in 0..children.len-1: result.s[i] = children[i]
  result.fAttr = attributes

proc text*(n: XmlNode): string {.inline.} =
  ## Gets the associated text with the node `n`.
  ##
  ## `n` can be a CDATA, Text, comment, or entity node.
  ##
  ## See also:
  ## * `text= proc <#text=,XmlNode,string>`_ for text setter
  ## * `tag proc <#tag,XmlNode>`_ for tag getter
  ## * `tag= proc <#tag=,XmlNode,string>`_ for tag setter
  ## * `innerText proc <#innerText,XmlNode>`_
  runnableExamples:
    var c = newComment("my comment")
    assert $c == "<!-- my comment -->"
    assert c.text == "my comment"

  assert n.k in {xnText, xnComment, xnCData, xnEntity}
  result = n.fText

proc `text=`*(n: XmlNode, text: string){.inline.} =
  ## Sets the associated text with the node `n`.
  ##
  ## `n` can be a CDATA, Text, comment, or entity node.
  ##
  ## See also:
  ## * `text proc <#text,XmlNode>`_ for text getter
  ## * `tag proc <#tag,XmlNode>`_ for tag getter
  ## * `tag= proc <#tag=,XmlNode,string>`_ for tag setter
  runnableExamples:
    var e = newEntity("my entity")
    assert $e == "&my entity;"
    e.text = "a new entity text"
    assert $e == "&a new entity text;"

  assert n.k in {xnText, xnComment, xnCData, xnEntity}
  n.fText = text

proc tag*(n: XmlNode): string {.inline.} =
  ## Gets the tag name of `n`.
  ##
  ## `n` has to be an ``xnElement`` node.
  ##
  ## See also:
  ## * `text proc <#text,XmlNode>`_ for text getter
  ## * `text= proc <#text=,XmlNode,string>`_ for text setter
  ## * `tag= proc <#tag=,XmlNode,string>`_ for tag setter
  ## * `innerText proc <#innerText,XmlNode>`_
  runnableExamples:
    var a = newElement("firstTag")
    a.add newElement("childTag")
    assert $a == """<firstTag>
  <childTag>
  </childTag>
</firstTag>"""
    assert a.tag == "firstTag"

  assert n.k == xnElement
  result = n.fTag

proc `tag=`*(n: XmlNode, tag: string) {.inline.} =
  ## Sets the tag name of `n`.
  ##
  ## `n` has to be an ``xnElement`` node.
  ##
  ## See also:
  ## * `text proc <#text,XmlNode>`_ for text getter
  ## * `text= proc <#text=,XmlNode,string>`_ for text setter
  ## * `tag proc <#tag,XmlNode>`_ for tag getter
  runnableExamples:
    var a = newElement("firstTag")
    a.add newElement("childTag")
    assert $a == """<firstTag>
  <childTag>
  </childTag>
</firstTag>"""
    a.tag = "newTag"
    assert $a == """<newTag>
  <childTag>
  </childTag>
</newTag>"""

  assert n.k == xnElement
  n.fTag = tag

proc rawText*(n: XmlNode): string {.inline.} =
  ## Returns the underlying 'text' string by reference.
  ##
  ## This is only used for speed hacks.
  when defined(gcDestructors):
    result = move(n.fText)
  else:
    shallowCopy(result, n.fText)

proc rawTag*(n: XmlNode): string {.inline.} =
  ## Returns the underlying 'tag' string by reference.
  ##
  ## This is only used for speed hacks.
  when defined(gcDestructors):
    result = move(n.fTag)
  else:
    shallowCopy(result, n.fTag)

proc innerText*(n: XmlNode): string =
  ## Gets the inner text of `n`:
  ##
  ## - If `n` is `xnText` or `xnEntity`, returns its content.
  ## - If `n` is `xnElement`, runs recursively on each child node and
  ##   concatenates the results.
  ## - Otherwise returns an empty string.
  ##
  ## See also:
  ## * `text proc <#text,XmlNode>`_
  runnableExamples:
    var f = newElement("myTag")
    f.add newText("my text")
    f.add newComment("my comment")
    f.add newEntity("my entity")
    assert $f == "<myTag>my text<!-- my comment -->&my entity;</myTag>"
    assert innerText(f) == "my textmy entity"

  proc worker(res: var string, n: XmlNode) =
    case n.k
    of xnText, xnEntity:
      res.add(n.fText)
    of xnElement:
      for sub in n.s:
        worker(res, sub)
    else:
      discard

  result = ""
  worker(result, n)

proc add*(father, son: XmlNode) {.inline.} =
  ## Adds the child `son` to `father`.
  ##
  ## See also:
  ## * `insert proc <#insert,XmlNode,XmlNode,int>`_
  ## * `delete proc <#delete,XmlNode,Natural>`_
  runnableExamples:
    var f = newElement("myTag")
    f.add newText("my text")
    f.add newElement("sonTag")
    f.add newEntity("my entity")
    assert $f == "<myTag>my text<sonTag></sonTag>&my entity;</myTag>"
  add(father.s, son)

proc insert*(father, son: XmlNode, index: int) {.inline.} =
  ## Insert the child `son` to a given position in `father`.
  ##
  ## `father` and `son` must be of `xnElement` kind.
  ##
  ## See also:
  ## * `add proc <#add,XmlNode,XmlNode>`_
  ## * `delete proc <#delete,XmlNode,Natural>`_
  runnableExamples:
    var f = newElement("myTag")
    f.add newElement("first")
    f.insert(newElement("second"), 0)
    assert $f == """<myTag>
  <second>
  </second>
  <first>
  </first>
</myTag>"""

  assert father.k == xnElement and son.k == xnElement
  if len(father.s) > index:
    insert(father.s, son, index)
  else:
    insert(father.s, son, len(father.s))

proc delete*(n: XmlNode, i: Natural) {.noSideEffect.} =
  ## Delete the `i`'th child of `n`.
  ##
  ## See also:
  ## * `add proc <#add,XmlNode,XmlNode>`_
  ## * `insert proc <#insert,XmlNode,XmlNode,int>`_
  runnableExamples:
    var f = newElement("myTag")
    f.add newElement("first")
    f.insert(newElement("second"), 0)
    f.delete(0)
    assert $f == """<myTag>
  <first>
  </first>
</myTag>"""

  assert n.k == xnElement
  n.s.delete(i)

proc len*(n: XmlNode): int {.inline.} =
  ## Returns the number of `n`'s children.
  runnableExamples:
    var f = newElement("myTag")
    f.add newElement("first")
    f.insert(newElement("second"), 0)
    assert len(f) == 2
  if n.k == xnElement: result = len(n.s)

proc kind*(n: XmlNode): XmlNodeKind {.inline.} =
  ## Returns `n`'s kind.
  runnableExamples:
    var a = newElement("firstTag")
    assert a.kind == xnElement
    var b = newText("my text")
    assert b.kind == xnText
  result = n.k

proc `[]`*(n: XmlNode, i: int): XmlNode {.inline.} =
  ## Returns the `i`'th child of `n`.
  runnableExamples:
    var f = newElement("myTag")
    f.add newElement("first")
    f.insert(newElement("second"), 0)
    assert $f[1] == "<first>\n</first>"
    assert $f[0] == "<second>\n</second>"

  assert n.k == xnElement
  result = n.s[i]

proc `[]`*(n: var XmlNode, i: int): var XmlNode {.inline.} =
  ## Returns the `i`'th child of `n` so that it can be modified.
  assert n.k == xnElement
  result = n.s[i]

proc clear*(n: var XmlNode) =
  ## Recursively clear all children of an XmlNode.
  ##
  ## .. code-block::
  ##   var g = newElement("myTag")
  ##   g.add newText("some text")
  ##   g.add newComment("this is comment")
  ##
  ##   var h = newElement("secondTag")
  ##   h.add newEntity("some entity")
  ##
  ##   let att = {"key1": "first value", "key2": "second value"}.toXmlAttributes
  ##   var k = newXmlTree("treeTag", [g, h], att)
  ##
  ##   echo k
  ##   ## <treeTag key2="second value" key1="first value">
  ##   ##   <myTag>some text<!-- this is comment --></myTag>
  ##   ##   <secondTag>&some entity;</secondTag>
  ##   ## </treeTag>
  ##
  ##   clear(k)
  ##   echo k
  ##   ## <treeTag key2="second value" key1="first value" />

  for i in 0 ..< n.len:
    clear(n[i])
  if n.k == xnElement:
    n.s.setLen(0)


iterator items*(n: XmlNode): XmlNode {.inline.} =
  ## Iterates over all direct children of `n`.
  ##
  ## **Examples:**
  ##
  ## .. code-block::
  ##   var g = newElement("myTag")
  ##   g.add newText("some text")
  ##   g.add newComment("this is comment")
  ##
  ##   var h = newElement("secondTag")
  ##   h.add newEntity("some entity")
  ##   g.add h
  ##
  ##   assert $g == "<myTag>some text<!-- this is comment --><secondTag>&some entity;</secondTag></myTag>"
  ##   for x in g: # the same as `for x in items(g):`
  ##     echo x
  ##
  ##   # some text
  ##   # <!-- this is comment -->
  ##   # <secondTag>&some entity;<![CDATA[some cdata]]></secondTag>

  assert n.k == xnElement
  for i in 0 .. n.len-1: yield n[i]

iterator mitems*(n: var XmlNode): var XmlNode {.inline.} =
  ## Iterates over all direct children of `n` so that they can be modified.
  assert n.k == xnElement
  for i in 0 .. n.len-1: yield n[i]

proc toXmlAttributes*(keyValuePairs: varargs[tuple[key,
    val: string]]): XmlAttributes =
  ## Converts `{key: value}` pairs into `XmlAttributes`.
  ##
  ## .. code-block::
  ##   let att = {"key1": "first value", "key2": "second value"}.toXmlAttributes
  ##   var j = newElement("myTag")
  ##   j.attrs = att
  ##
  ##   echo j
  ##   ## <myTag key2="second value" key1="first value" />

  newStringTable(keyValuePairs)

proc attrs*(n: XmlNode): XmlAttributes {.inline.} =
  ## Gets the attributes belonging to `n`.
  ##
  ## Returns `nil` if attributes have not been initialised for this node.
  ##
  ## See also:
  ## * `attrs= proc <#attrs=,XmlNode,XmlAttributes>`_ for XmlAttributes setter
  ## * `attrsLen proc <#attrsLen,XmlNode>`_ for number of attributes
  ## * `attr proc <#attr,XmlNode,string>`_ for finding an attribute
  runnableExamples:
    var j = newElement("myTag")
    assert j.attrs == nil
    let att = {"key1": "first value", "key2": "second value"}.toXmlAttributes
    j.attrs = att
    assert j.attrs == att

  assert n.k == xnElement
  result = n.fAttr

proc `attrs=`*(n: XmlNode, attr: XmlAttributes) {.inline.} =
  ## Sets the attributes belonging to `n`.
  ##
  ## See also:
  ## * `attrs proc <#attrs,XmlNode>`_ for XmlAttributes getter
  ## * `attrsLen proc <#attrsLen,XmlNode>`_ for number of attributes
  ## * `attr proc <#attr,XmlNode,string>`_ for finding an attribute
  runnableExamples:
    var j = newElement("myTag")
    assert j.attrs == nil
    let att = {"key1": "first value", "key2": "second value"}.toXmlAttributes
    j.attrs = att
    assert j.attrs == att

  assert n.k == xnElement
  n.fAttr = attr

proc attrsLen*(n: XmlNode): int {.inline.} =
  ## Returns the number of `n`'s attributes.
  ##
  ## See also:
  ## * `attrs proc <#attrs,XmlNode>`_ for XmlAttributes getter
  ## * `attrs= proc <#attrs=,XmlNode,XmlAttributes>`_ for XmlAttributes setter
  ## * `attr proc <#attr,XmlNode,string>`_ for finding an attribute
  runnableExamples:
    var j = newElement("myTag")
    assert j.attrsLen == 0
    let att = {"key1": "first value", "key2": "second value"}.toXmlAttributes
    j.attrs = att
    assert j.attrsLen == 2

  assert n.k == xnElement
  if not isNil(n.fAttr): result = len(n.fAttr)

proc attr*(n: XmlNode, name: string): string =
  ## Finds the first attribute of `n` with a name of `name`.
  ## Returns "" on failure.
  ##
  ## See also:
  ## * `attrs proc <#attrs,XmlNode>`_ for XmlAttributes getter
  ## * `attrs= proc <#attrs=,XmlNode,XmlAttributes>`_ for XmlAttributes setter
  ## * `attrsLen proc <#attrsLen,XmlNode>`_ for number of attributes
  runnableExamples:
    var j = newElement("myTag")
    let att = {"key1": "first value", "key2": "second value"}.toXmlAttributes
    j.attrs = att
    assert j.attr("key1") == "first value"
    assert j.attr("key2") == "second value"

  assert n.kind == xnElement
  if n.attrs == nil: return ""
  return n.attrs.getOrDefault(name)

proc clientData*(n: XmlNode): int {.inline.} =
  ## Gets the client data of `n`.
  ##
  ## The client data field is used by the HTML parser and generator.
  result = n.fClientData

proc `clientData=`*(n: XmlNode, data: int) {.inline.} =
  ## Sets the client data of `n`.
  ##
  ## The client data field is used by the HTML parser and generator.
  n.fClientData = data

proc addEscaped*(result: var string, s: string) =
  ## The same as `result.add(escape(s)) <#escape,string>`_, but more efficient.
  for c in items(s):
    case c
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '&': result.add("&amp;")
    of '"': result.add("&quot;")
    of '\'': result.add("&apos;")
    else: result.add(c)

proc escape*(s: string): string =
  ## Escapes `s` for inclusion into an XML document.
  ##
  ## Escapes these characters:
  ##
  ## ------------    -------------------
  ## char            is converted to
  ## ------------    -------------------
  ##  ``<``          ``&lt;``
  ##  ``>``          ``&gt;``
  ##  ``&``          ``&amp;``
  ##  ``"``          ``&quot;``
  ##  ``'``          ``&apos;``
  ## ------------    -------------------
  ##
  ## You can also use `addEscaped proc <#addEscaped,string,string>`_.
  result = newStringOfCap(s.len)
  addEscaped(result, s)

proc addIndent(result: var string, indent: int, addNewLines: bool) =
  if addNewLines:
    result.add("\n")
  for i in 1 .. indent:
    result.add(' ')

proc add*(result: var string, n: XmlNode, indent = 0, indWidth = 2,
          addNewLines = true) =
  ## Adds the textual representation of `n` to string `result`.
  runnableExamples:
    var
      a = newElement("firstTag")
      b = newText("my text")
      c = newComment("my comment")
      s = ""
    s.add(c)
    a.add(b)
    s.add(a)
    assert s == "<!-- my comment --><firstTag>my text</firstTag>"

  proc noWhitespace(n: XmlNode): bool =
    for i in 0 ..< n.len:
      if n[i].kind in {xnText, xnEntity}: return true

  proc addEscapedAttr(result: var string, s: string) =
    # `addEscaped` alternative with less escaped characters.
    # Only to be used for escaping attribute values enclosed in double quotes!
    for c in items(s):
      case c
      of '<': result.add("&lt;")
      of '>': result.add("&gt;")
      of '&': result.add("&amp;")
      of '"': result.add("&quot;")
      else: result.add(c)

  if n == nil: return

  case n.k
  of xnElement:
    if indent > 0:
      result.addIndent(indent, addNewLines)

    let
      addNewLines = if n.noWhitespace():
                      false
                    else:
                      addNewLines

    result.add('<')
    result.add(n.fTag)
    if not isNil(n.fAttr):
      for key, val in pairs(n.fAttr):
        result.add(' ')
        result.add(key)
        result.add("=\"")
        result.addEscapedAttr(val)
        result.add('"')

    if n.len == 0 and n.fTag in singleTags:
      result.add("/>")
      return

    let
      indentNext = if n.noWhitespace():
                     indent
                   else:
                     indent+indWidth
    result.add('>')
    for i in 0 ..< n.len:
      result.add(n[i], indentNext, indWidth, addNewLines)

    if not n.noWhitespace():
      result.addIndent(indent, addNewLines)

    result.add("</")
    result.add(n.fTag)
    result.add(">")
  of xnText:
    result.addEscaped(n.fText)
  of xnVerbatimText:
    result.add(n.fText)
  of xnComment:
    result.add("<!-- ")
    result.addEscaped(n.fText)
    result.add(" -->")
  of xnCData:
    result.add("<![CDATA[")
    result.add(n.fText)
    result.add("]]>")
  of xnEntity:
    result.add('&')
    result.add(n.fText)
    result.add(';')

proc `$`*(n: XmlNode): string =
  ## Converts `n` into its string representation.
  ##
  ## No ``<$xml ...$>`` declaration is produced, so that the produced
  ## XML fragments are composable.
  result = ""
  result.add(n)

proc child*(n: XmlNode, name: string): XmlNode =
  ## Finds the first child element of `n` with a name of `name`.
  ## Returns `nil` on failure.
  runnableExamples:
    var f = newElement("myTag")
    f.add newElement("firstSon")
    f.add newElement("secondSon")
    f.add newElement("thirdSon")
    assert $(f.child("secondSon")) == "<secondSon>\n</secondSon>"

  assert n.kind == xnElement
  for i in items(n):
    if i.kind == xnElement:
      if i.tag == name:
        return i

proc findAll*(n: XmlNode, tag: string, result: var seq[XmlNode],
    caseInsensitive = false) =
  ## Iterates over all the children of `n` returning those matching `tag`.
  ##
  ## Found nodes satisfying the condition will be appended to the `result`
  ## sequence.
  runnableExamples:
    var
      b = newElement("good")
      c = newElement("bad")
      d = newElement("BAD")
      e = newElement("GOOD")
    b.add newText("b text")
    c.add newText("c text")
    d.add newText("d text")
    e.add newText("e text")
    let a = newXmlTree("father", [b, c, d, e])
    var s = newSeq[XmlNode]()
    a.findAll("good", s)
    assert $s == "@[<good>b text</good>]"
    s.setLen(0)
    a.findAll("good", s, caseInsensitive = true)
    assert $s == "@[<good>b text</good>, <GOOD>e text</GOOD>]"
    s.setLen(0)
    a.findAll("BAD", s)
    assert $s == "@[<BAD>d text</BAD>]"
    s.setLen(0)
    a.findAll("BAD", s, caseInsensitive = true)
    assert $s == "@[<bad>c text</bad>, <BAD>d text</BAD>]"

  assert n.k == xnElement
  for child in n.items():
    if child.k != xnElement:
      continue
    if child.tag == tag or
        (caseInsensitive and cmpIgnoreCase(child.tag, tag) == 0):
      result.add(child)
    child.findAll(tag, result)

proc findAll*(n: XmlNode, tag: string, caseInsensitive = false): seq[XmlNode] =
  ## A shortcut version to assign in let blocks.
  runnableExamples:
    var
      b = newElement("good")
      c = newElement("bad")
      d = newElement("BAD")
      e = newElement("GOOD")
    b.add newText("b text")
    c.add newText("c text")
    d.add newText("d text")
    e.add newText("e text")
    let a = newXmlTree("father", [b, c, d, e])
    assert $(a.findAll("good")) == "@[<good>b text</good>]"
    assert $(a.findAll("BAD")) == "@[<BAD>d text</BAD>]"
    assert $(a.findAll("good", caseInsensitive = true)) == "@[<good>b text</good>, <GOOD>e text</GOOD>]"
    assert $(a.findAll("BAD", caseInsensitive = true)) == "@[<bad>c text</bad>, <BAD>d text</BAD>]"

  newSeq(result, 0)
  findAll(n, tag, result, caseInsensitive)

proc xmlConstructor(a: NimNode): NimNode {.compileTime.} =
  if a.kind == nnkCall:
    result = newCall("newXmlTree", toStrLit(a[0]))
    var attrs = newNimNode(nnkBracket, a)
    var newStringTabCall = newCall(bindSym"newStringTable", attrs,
                                    bindSym"modeCaseSensitive")
    var elements = newNimNode(nnkBracket, a)
    for i in 1..a.len-1:
      if a[i].kind == nnkExprEqExpr:
        # In order to support attributes like `data-lang` we have to
        # replace whitespace because `toStrLit` gives `data - lang`.
        let attrName = toStrLit(a[i][0]).strVal.replace(" ", "")
        attrs.add(newStrLitNode(attrName))
        attrs.add(a[i][1])
        #echo repr(attrs)
      else:
        elements.add(a[i])
    result.add(elements)
    if attrs.len > 1:
      #echo repr(newStringTabCall)
      result.add(newStringTabCall)
  else:
    result = newCall("newXmlTree", toStrLit(a))

macro `<>`*(x: untyped): untyped =
  ## Constructor macro for XML. Example usage:
  ##
  ## .. code-block:: nim
  ##   <>a(href="http://nim-lang.org", newText("Nim rules."))
  ##
  ## Produces an XML tree for::
  ##
  ##  <a href="http://nim-lang.org">Nim rules.</a>
  ##
  result = xmlConstructor(x)


when isMainModule:
  var
    x: XmlNode

  x = <>a(href = "http://nim-lang.org", newText("Nim rules."))
  assert $x == """<a href="http://nim-lang.org">Nim rules.</a>"""

  x = <>outer(<>inner())
  assert $x == """<outer>
  <inner />
</outer>"""

  x = <>outer(<>middle(<>inner1(), <>inner2(), <>inner3(), <>inner4()))
  assert $x == """<outer>
  <middle>
    <inner1 />
    <inner2 />
    <inner3 />
    <inner4 />
  </middle>
</outer>"""

  x = <>l0(<>l1(<>l2(<>l3(<>l4()))))
  assert $x == """<l0>
  <l1>
    <l2>
      <l3>
        <l4 />
      </l3>
    </l2>
  </l1>
</l0>"""

  x = <>l0(<>l1p1(), <>l1p2(), <>l1p3())
  assert $x == """<l0>
  <l1p1 />
  <l1p2 />
  <l1p3 />
</l0>"""

  x = <>l0(<>l1(<>l2p1(), <>l2p2()))
  assert $x == """<l0>
  <l1>
    <l2p1 />
    <l2p2 />
  </l1>
</l0>"""

  x = <>l0(<>l1(<>l2_1(), <>l2_2(<>l3_1(), <>l3_2(), <>l3_3(<>l4_1(), <>l4_2(), <>l4_3())), <>l2_3(), <>l2_4()))
  assert $x == """<l0>
  <l1>
    <l2_1 />
    <l2_2>
      <l3_1 />
      <l3_2 />
      <l3_3>
        <l4_1 />
        <l4_2 />
        <l4_3 />
      </l3_3>
    </l2_2>
    <l2_3 />
    <l2_4 />
  </l1>
</l0>"""

  let
    innermost = newElement("innermost")
    middle = newXmlTree("middle", [innermost])
  innermost.add newText("innermost text")
  x = newXmlTree("outer", [middle])
  assert $x == """<outer>
  <middle>
    <innermost>innermost text</innermost>
  </middle>
</outer>"""

  x = newElement("myTag")
  x.add newText("my text")
  x.add newElement("sonTag")
  x.add newEntity("my entity")
  assert $x == "<myTag>my text<sonTag />&my entity;</myTag>"
