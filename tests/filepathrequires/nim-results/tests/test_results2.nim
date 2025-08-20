import ../results

{.used.}

# Oddly, this piece of code works when placed in `test_results.nim`
# See also https://github.com/status-im/nim-stew/pull/167

template repeater(b: Opt[int]): untyped =
  # Check that Result can be used inside a template - this fails
  # sometimes with field access errors as noted in above issue
  b

let x = repeater(Opt.none(int))
doAssert x.isNone()
