# Introduction

Result type that can hold either a value or an error, but not both

## Usage

Add the following to your `.nimble` file:

```
requires "results"
```

or just drop the file in your project!

## Example

```nim
import results

# Re-export `results` so that API is always available to users of your module!
export results

# It's convenient to create an alias - most likely, you'll do just fine
# with strings or cstrings as error for a start

type R = Result[int, string]

# Once you have a type, use `ok` and `err`:

func works(): R =
  # ok says it went... ok!
  R.ok 42
func fails(): R =
  # or type it like this, to not repeat the type:
  result.err "bad luck"

func alsoWorks(): R =
  # or just use the shortcut - auto-deduced from the return type!
  ok(24)

if (let w = works(); w.isOk):
  echo w[], " or use value: ", w.value

# In case you think your callers want to differentiate between errors:
type
  Error = enum
    a, b, c
  type RE[T] = Result[T, Error]

# You can use the question mark operator to pass errors up the call stack
func f(): R =
  let x = ?works() - ?fails()
  assert false, "will never reach"

# If you provide this exception converter, this exception will be raised on
# `tryGet`:
func toException(v: Error): ref CatchableError = (ref CatchableError)(msg: $v)
try:
  RE[int].err(a).tryGet()
except CatchableError:
  echo "in here!"

# You can use `Opt[T]` as a replacement for `Option` = `Opt` is an alias for
# `Result[T, void]`, meaning you can use the full `Result` API on it:
let x = Opt[int].ok(42)
echo x.get()

# ... or `Result[void, E]` as a replacement for `bool`, providing extra error
# information!
let y = Result[void, string].err("computation failed")
echo y.error()


```

See [results.nim](./results.nim) for more in-depth documentation - specially
towards the end where there are plenty of examples!

## License

MIT license, just like Nim, or Apache, if you prefer that

