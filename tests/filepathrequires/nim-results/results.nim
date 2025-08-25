# Copyright (c) 2019 Jacek Sieka
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

type
  ResultError*[E] = object of ValueError
    ## Error raised when using `tryValue` value of result when error is set
    ## See also Exception bridge mode
    error*: E

  ResultDefect* = object of Defect
    ## Defect raised when accessing value when error is set and vice versa
    ## See also Exception bridge mode

  Result*[T, E] = object
    ## Result type that can hold either a value or an error, but not both
    ##
    ## # Example
    ##
    ## ```
    ## import results
    ##
    ## # Re-export `results` so that API is always available to users of your module!
    ## export results
    ##
    ## # It's convenient to create an alias - most likely, you'll do just fine
    ## # with strings or cstrings as error for a start
    ##
    ## type R = Result[int, string]
    ##
    ## # Once you have a type, use `ok` and `err`:
    ##
    ## func works(): R =
    ##   # ok says it went... ok!
    ##   R.ok 42
    ## func fails(): R =
    ##   # or type it like this, to not repeat the type:
    ##   result.err "bad luck"
    ##
    ## func alsoWorks(): R =
    ##   # or just use the shortcut - auto-deduced from the return type!
    ##   ok(24)
    ##
    ## if (let w = works(); w.isOk):
    ##   echo w[], " or use value: ", w.value
    ##
    ## # In case you think your callers want to differentiate between errors:
    ## type
    ##   Error = enum
    ##     a, b, c
    ##   type RE[T] = Result[T, Error]
    ##
    ## # You can use the question mark operator to pass errors up the call stack
    ## func f(): R =
    ##   let x = ?works() - ?fails()
    ##   assert false, "will never reach"
    ##
    ## # If you provide this exception converter, this exception will be raised on
    ## # `tryValue`:
    ## func toException(v: Error): ref CatchableError = (ref CatchableError)(msg: $v)
    ## try:
    ##   RE[int].err(a).tryValue()
    ## except CatchableError:
    ##   echo "in here!"
    ##
    ## # You can use `Opt[T]` as a replacement for `Option` = `Opt` is an alias for
    ## # `Result[T, void]`, meaning you can use the full `Result` API on it:
    ## let x = Opt[int].ok(42)
    ## echo x.get()
    ##
    ## # ... or `Result[void, E]` as a replacement for `bool`, providing extra error
    ## # information!
    ## let y = Result[void, string].err("computation failed")
    ## echo y.error()
    ##
    ## ```
    ##
    ## See the tests for more practical examples, specially when working with
    ## back and forth with the exception world!
    ##
    ## # Potential benefits:
    ##
    ## * Handling errors becomes explicit and mandatory at the call site -
    ##   goodbye "out of sight, out of mind"
    ## * Errors are a visible part of the API - when they change, so must the
    ##   calling code and compiler will point this out - nice!
    ## * Errors are a visible part of the API - your fellow programmer is
    ##   reminded that things actually can go wrong
    ## * Jives well with Nim `discard`
    ## * Jives well with the new Defect exception hierarchy, where defects
    ##   are raised for unrecoverable errors and the rest of the API uses
    ##   results
    ## * Error and value return have similar performance characteristics
    ## * Caller can choose to turn them into exceptions at low cost - flexible
    ##   for libraries!
    ## * Mostly relies on simple Nim features - though this library is no
    ##   exception in that compiler bugs were discovered writing it :)
    ##
    ## # Potential costs:
    ##
    ## * Handling errors becomes explicit and mandatory - if you'd rather ignore
    ##   them or just pass them to some catch-all, this is noise
    ## * When composing operations, value must be lifted before processing,
    ##   adding potential verbosity / noise (fancy macro, anyone?)
    ## * There's no call stack captured by default (see also `catch` and
    ##   `capture`)
    ## * The extra branching may be more expensive for the non-error path
    ##   (though this can be minimized with PGO)
    ##
    ## The API visibility issue of exceptions can also be solved with
    ## `{.raises.}` annotations - as of now, the compiler doesn't remind
    ## you to do so, even though it knows what the right annotation should be.
    ## `{.raises.}` does not participate in generic typing, making it just as
    ## verbose but less flexible in some ways, if you want to type it out.
    ##
    ## Many system languages make a distinction between errors you want to
    ## handle and those that are simply bugs or unrealistic to deal with..
    ## handling the latter will often involve aborting or crashing the funcess -
    ## reliable systems like Erlang will try to relaunch it.
    ##
    ## On the flip side we have dynamic languages like python where there's
    ## nothing exceptional about exceptions (hello StopIterator). Python is
    ## rarely used to build reliable systems - its strengths lie elsewhere.
    ##
    ## # Exception bridge mode
    ##
    ## When the error of a `Result` is an `Exception`, or a `toException` helper
    ## is present for your error type, the "Exception bridge mode" is
    ## enabled and instead of raising `ResultError`, `tryValue` will raise the
    ## given `Exception` on access. `[]` and `value` will continue to raise a
    ## `Defect`.
    ##
    ## This is an experimental feature that may be removed.
    ##
    ## # Other languages
    ##
    ## Result-style error handling seems pretty popular lately, specially with
    ## statically typed languages:
    ## Haskell: https://hackage.haskell.org/package/base-4.11.1.0/docs/Data-Either.html
    ## Rust: https://doc.rust-lang.org/std/result/enum.Result.html
    ## Modern C++: https://en.cppreference.com/w/cpp/utility/expected
    ## More C++: https://github.com/ned14/outcome
    ##
    ## Swift is interesting in that it uses a non-exception implementation but
    ## calls errors exceptions and has lots of syntactic sugar to make them feel
    ## that way by implicitly passing them up the call chain - with a mandatory
    ## annotation that function may throw:
    ## https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/ErrorHandling.html
    ##
    ## # Considerations for the error type
    ##
    ## * Use a `string` or a `cstring` if you want to provide a diagnostic for
    ##   the caller without an expectation that they will differentiate between
    ##   different errors. Callers should never parse the given string!
    ## * Use an `enum` to provide in-depth errors where the caller is expected
    ##   to have different logic for different errors
    ## * Use a complex type to include error-specific meta-data - or make the
    ##   meta-data collection a visible part of your API in another way - this
    ##   way it remains discoverable by the caller!
    ##
    ## A natural "error API" progression is starting with `Opt[T]`, then
    ## `Result[T, cstring]`, `Result[T, enum]` and `Result[T, object]` in
    ## escalating order of complexity.
    ##
    ## # Result equivalences with other types
    ##
    ## Result allows tightly controlling the amount of information that a
    ## function gives to the caller:
    ##
    ## ## `Result[void, void] == bool`
    ##
    ## Neither value nor error information, it either worked or didn't. Most
    ## often used for `proc`:s with side effects.
    ##
    ## ## `Result[T, void] == Option[T]`
    ##
    ## Return value if it worked, else tell the caller it failed. Most often
    ## used for simple computations.
    ##
    ## Works as a replacement for `Option[T]` (aliased as `Opt[T]`)
    ##
    ## ## `Result[T, E]` -
    ##
    ## Return value if it worked, or a statically known piece of information
    ## when it didn't - most often used when a function can fail in more than
    ## one way - E is typically a `string` or an `enum`.
    ##
    ## ## `Result[T, ref E]`
    ##
    ## Returning a `ref E` allows introducing dynamically typed error
    ## information, similar to exceptions.
    ##
    ## # Other implemenations in nim
    ##
    ## There are other implementations in nim that you might prefer:
    ## * Either from nimfp: https://github.com/vegansk/nimfp/blob/master/src/fp/either.nim
    ## * result_type: https://github.com/kapralos/result_type/
    ##
    ## `Option` compatibility
    ##
    ## `Result[T, void]` is similar to `Option[T]`, except it can be used with
    ## all `Result` operators and helpers.
    ##
    ## One difference is `Option[ref|ptr T]` which disallows `nil` - `Opt[T]`
    ## allows an "ok" result to hold `nil` - this can be useful when `nil` is
    ## a valid outcome of a function, but increases complexity for the caller.
    ##
    ## # Implementation notes
    ##
    ## This implementation is mostly based on the one in rust. Compared to it,
    ## there are a few differences - if know of creative ways to improve things,
    ## I'm all ears.
    ##
    ## * Rust has the enum variants which lend themselves to nice construction
    ##   where the full Result type isn't needed: `Err("some error")` doesn't
    ##   need to know value type - maybe some creative converter or something
    ##   can deal with this?
    ## * Nim templates allow us to fail fast without extra effort, meaning the
    ##   other side of `and`/`or` isn't evaluated unless necessary - nice!
    ## * Rust uses From traits to deal with result translation as the result
    ##   travels up the call stack - needs more tinkering - some implicit
    ##   conversions would be nice here
    ## * Pattern matching in rust allows convenient extraction of value or error
    ##   in one go.
    ##
    ## # Performance considerations
    ##
    ## When returning a Result instead of a simple value, there are a few things
    ## to take into consideration - in general, we are returning more
    ## information directly to the caller which has an associated cost.
    ##
    ## Result is a value type, thus its performance characteristics
    ## generally follow the performance of copying the value or error that
    ## it stores. `Result` would benefit greatly from "move" support in the
    ## language.
    ##
    ## In many cases, these performance costs are negligeable, but nonetheless
    ## they are important to be aware of, to structure your code in an efficient
    ## manner:
    ##
    ## * Memory overhead
    ##   Result is stored in memory as a union with a `bool` discriminator -
    ##   alignment makes it somewhat tricky to give an exact size, but in
    ##   general, `Result[int, int]` will take up `2*sizeof(int)` bytes:
    ##   1 `int` for the discriminator and padding, 1 `int` for either the value
    ##   or the error. The additional size means that returning may take up more
    ##   registers or spill onto the stack.
    ## * Loss of RVO
    ##   Nim does return-value-optimization by rewriting `proc f(): X` into
    ##   `proc f(result: var X)` - in an expression like `let x = f()`, this
    ##   allows it to avoid a copy from the "temporary" return value to `x` -
    ##   when using Result, this copy currently happens always because you need
    ##   to fetch the value from the Result in a second step: `let x = f().value`
    ## * Extra copies
    ##   To avoid spurious evaluation of expressions in templates, we use a
    ##   temporary variable sometimes - this means an unnecessary copy for some
    ##   types.
    ## * Bad codegen
    ##   When doing RVO, Nim generates poor and slow code: it uses a construct
    ##   called `genericReset` that will zero-initialize a value using dynamic
    ##   RTTI - a process that the C compiler subsequently is unable to
    ##   optimize. This applies to all types, but is exacerbated with Result
    ##   because of its bigger footprint - this should be fixed in compiler.
    ## * Double zero-initialization bug
    ##   Nim has an initialization bug that causes additional poor performance:
    ##   `var x = f()` will be expanded into `var x; zeroInit(x); f(x)` where
    ##   `f(x)` will call the slow `genericReset` and zero-init `x` again,
    ##   unnecessarily.
    ##
    ## Comparing `Result` performance to exceptions in Nim is difficult - it
    ## will depend on the error type used, the frequency at which exceptions
    ## happen, the amount of error handling code in the application and the
    ## compiler and backend used.
    ##
    ## * the default C backend in nim uses `setjmp` for exception handling -
    ##   the relative performance of the happy path will depend on the structure
    ##   of the code: how many exception handlers there are, how much unwinding
    ##   happens. `setjmp` works by taking a snapshot of the full CPU state and
    ##   saving it to memory when enterting a try block (or an implict try
    ##   block, such as is introduced with `defer` and similar constructs).
    ## * an efficient exception handling mechanism (like the C++ backend or
    ##   `nlvm`) will usually have a lower cost on the happy path because the
    ##   value can be returned more efficiently. However, there is still a code
    ##   and data size increase depending on the specific situation, as well as
    ##   loss of optimization opportunities to consider.
    ## * raising an exception is usually (a lot) slower than returning an error
    ##   through a Result - at raise time, capturing a call stack and allocating
    ##   memory for the Exception is expensive, so the performance difference
    ##   comes down to the complexity of the error type used.
    ## * checking for errors with Result is local branching operation that also
    ##   happens on the happy path - this may be a cost.
    ##
    ## An accurate summary might be that Exceptions are at its most efficient
    ## when errors are not handled and don't happen.
    ##
    ## # Relevant nim bugs
    ##
    ## https://github.com/nim-lang/Nim/issues/13799 - type issues
    ## https://github.com/nim-lang/Nim/issues/8745 - genericReset slow
    ## https://github.com/nim-lang/Nim/issues/13879 - double-zero-init slow
    ## https://github.com/nim-lang/Nim/issues/14318 - generic error raises pragma (fixed in 1.6.14+)
    ## https://github.com/nim-lang/Nim/issues/23741 - inefficient codegen for temporaries
    ## https://github.com/nim-lang/Nim/issues/20699 (fixed in 2.0.0+)
    # case oResultPrivate: bool
    # of false:
    #   eResultPrivate: E
    # of true:
    #   vResultPrivate: T

    # ResultPrivate* works around (fixed in 1.6.14+):
    # * https://github.com/nim-lang/Nim/issues/3770
    # * https://github.com/nim-lang/Nim/issues/20900
    #
    # Do not use these fields directly in your code, they're not meant to be
    # public!
    when T is void:
      when E is void:
        oResultPrivate*: bool
      else:
        case oResultPrivate*: bool
        of false:
          eResultPrivate*: E
        of true:
          discard
    else:
      when E is void:
        case oResultPrivate*: bool
        of false:
          discard
        of true:
          vResultPrivate*: T
      else:
        case oResultPrivate*: bool
        of false:
          eResultPrivate*: E
        of true:
          vResultPrivate*: T

  Opt*[T] = Result[T, void]

const
  resultsGenericsOpenSym* {.booldefine.} = true
    ## Enable the experimental `genericsOpenSym` feature or a workaround for the
    ## template injection problem in the issue linked below where scoped symbol
    ## resolution works differently for expanded bodies in templates depending on
    ## whether we're in a generic context or not.
    ##
    ## The issue leads to surprising errors where symbols from outer scopes get
    ## bound instead of the symbol created in the template scope which should be
    ## seen as a better candidate, breaking access to `error` in `valueOr` and
    ## friends.
    ##
    ## In Nim versions that do not support `genericsOpenSym`, a macro is used
    ## instead to reassign symbol matches which may or may not work depending on
    ## the complexity of the code.
    ##
    ## Nim 2.0.8 was released with an incomplete fix but already declares
    ## `nimHasGenericsOpenSym`.
    # TODO https://github.com/nim-lang/Nim/issues/22605
    # TODO https://github.com/arnetheduck/nim-results/issues/34
    # TODO https://github.com/nim-lang/Nim/issues/23386
    # TODO https://github.com/nim-lang/Nim/issues/23385
    #
    # Related PR:s (there's more probably, but this gives an overview)
    # https://github.com/nim-lang/Nim/pull/23102
    # https://github.com/nim-lang/Nim/pull/23572
    # https://github.com/nim-lang/Nim/pull/23873
    # https://github.com/nim-lang/Nim/pull/23892
    # https://github.com/nim-lang/Nim/pull/23939

  resultsGenericsOpenSymWorkaround* {.booldefine.} =
    resultsGenericsOpenSym and not defined(nimHasGenericsOpenSym2)
    ## Prefer macro workaround to solve genericsOpenSym issue
    # TODO https://github.com/nim-lang/Nim/pull/23892#discussion_r1713434311

  resultsGenericsOpenSymWorkaroundHint* {.booldefine.} = true

  resultsLent {.booldefine.} =
    (NimMajor, NimMinor, NimPatch) >= (2, 2, 0) or
    (defined(gcRefc) and ((NimMajor, NimMinor, NimPatch) >= (2, 0, 8)))
    ## Enable return of `lent` types - this *mostly* works in Nim 1.6.18+ but
    ## there have been edge cases reported as late as 1.6.14 - YMMV -
    ## conservatively, `lent` is therefore enabled only with the latest Nim
    ## version at the time of writing, where it could be verified to work with
    ## several large applications.
    ##
    ## ORC is not expected to work until 2.2.
    ## https://github.com/nim-lang/Nim/issues/23973

when resultsLent:
  template maybeLent(T: untyped): untyped =
    lent T

else:
  template maybeLent(T: untyped): untyped =
    T

func raiseResultOk[T, E](self: Result[T, E]) {.noreturn, noinline.} =
  # noinline because raising should take as little space as possible at call
  # site
  when T is void:
    raise (ref ResultError[void])(msg: "Trying to access error with value")
  else:
    raise (ref ResultError[T])(
      msg: "Trying to access error with value", error: self.vResultPrivate
    )

func raiseResultError[T, E](self: Result[T, E]) {.noreturn, noinline.} =
  # noinline because raising should take as little space as possible at call
  # site
  mixin toException

  when E is ref Exception:
    if self.eResultPrivate.isNil: # for example Result.default()!
      raise (ref ResultError[void])(msg: "Trying to access value with err (nil)")
    raise self.eResultPrivate
  elif E is void:
    raise (ref ResultError[void])(msg: "Trying to access value with err")
  elif compiles(toException(self.eResultPrivate)):
    raise toException(self.eResultPrivate)
  elif compiles($self.eResultPrivate):
    raise (ref ResultError[E])(error: self.eResultPrivate, msg: $self.eResultPrivate)
  else:
    raise (ref ResultError[E])(
      msg: "Trying to access value with err", error: self.eResultPrivate
    )

func raiseResultDefect(m: string, v: auto) {.noreturn, noinline.} =
  mixin `$`
  when compiles($v):
    raise (ref ResultDefect)(msg: m & ": " & $v)
  else:
    raise (ref ResultDefect)(msg: m)

func raiseResultDefect(m: string) {.noreturn, noinline.} =
  raise (ref ResultDefect)(msg: m)

template withAssertOk(self: Result, body: untyped): untyped =
  # Careful - `self` evaluated multiple times, which is fine in all current uses
  case self.oResultPrivate
  of false:
    when self.E isnot void:
      raiseResultDefect("Trying to access value with err Result", self.eResultPrivate)
    else:
      raiseResultDefect("Trying to access value with err Result")
  of true:
    body

template ok*[T: not void, E](R: type Result[T, E], x: untyped): R =
  ## Initialize a result with a success and value
  ## Example: `Result[int, string].ok(42)`
  R(oResultPrivate: true, vResultPrivate: x)

template ok*[E](R: type Result[void, E]): R =
  ## Initialize a result with a success and value
  ## Example: `Result[void, string].ok()`
  R(oResultPrivate: true)

template ok*[T: not void, E](self: var Result[T, E], x: untyped) =
  ## Set the result to success and update value
  ## Example: `result.ok(42)`
  self = ok(type self, x)

template ok*[E](self: var Result[void, E]) =
  ## Set the result to success and update value
  ## Example: `result.ok()`
  self = (type self).ok()

template err*[T; E: not void](R: type Result[T, E], x: untyped): R =
  ## Initialize the result to an error
  ## Example: `Result[int, string].err("uh-oh")`
  R(oResultPrivate: false, eResultPrivate: x)

template err*[T](R: type Result[T, cstring], x: string): R =
  ## Initialize the result to an error
  ## Example: `Result[int, string].err("uh-oh")`
  const s = x # avoid dangling cstring pointers
  R(oResultPrivate: false, eResultPrivate: cstring(s))

template err*[T](R: type Result[T, void]): R =
  ## Initialize the result to an error
  ## Example: `Result[int, void].err()`
  R(oResultPrivate: false)

template err*[T; E: not void](self: var Result[T, E], x: untyped) =
  ## Set the result as an error
  ## Example: `result.err("uh-oh")`
  self = err(type self, x)

template err*[T](self: var Result[T, cstring], x: string) =
  const s = x # Make sure we don't return a dangling pointer
  self = err(type self, cstring(s))

template err*[T](self: var Result[T, void]) =
  ## Set the result as an error
  ## Example: `result.err()`
  self = err(type self)

template ok*(v: auto): auto =
  ok(typeof(result), v)

template ok*(): auto =
  ok(typeof(result))

template err*(v: auto): auto =
  err(typeof(result), v)

template err*(): auto =
  err(typeof(result))

template isOk*(self: Result): bool =
  self.oResultPrivate

template isErr*(self: Result): bool =
  not self.oResultPrivate

when not defined(nimHasEffectsOfs):
  template effectsOf(f: untyped) {.pragma, used.}

func map*[T0: not void, E; T1: not void](
    self: Result[T0, E], f: proc(x: T0): T1
): Result[T1, E] {.inline, effectsOf: f.} =
  ## Transform value using f, or return error
  ##
  ## ```
  ## let r = Result[int, cstring).ok(42)
  ## assert r.map(proc (v: int): int = $v).value() == "42"
  ## ```
  case self.oResultPrivate
  of true:
    when T1 is void:
      f(self.vResultPrivate)
      result.ok()
    else:
      result.ok(f(self.vResultPrivate))
  of false:
    when E is void:
      result.err()
    else:
      result.err(self.eResultPrivate)

func map*[T: not void, E](
    self: Result[T, E], f: proc(x: T)
): Result[void, E] {.inline, effectsOf: f.} =
  ## Transform value using f, or return error
  ##
  ## ```
  ## let r = Result[int, cstring).ok(42)
  ## assert r.map(proc (v: int): int = $v).value() == "42"
  ## ```
  case self.oResultPrivate
  of true:
    f(self.vResultPrivate)
    result.ok()
  of false:
    when E is void:
      result.err()
    else:
      result.err(self.eResultPrivate)

func map*[E; T1: not void](
    self: Result[void, E], f: proc(): T1
): Result[T1, E] {.inline, effectsOf: f.} =
  ## Transform value using f, or return error
  case self.oResultPrivate
  of true:
    result.ok(f())
  of false:
    when E is void:
      result.err()
    else:
      result.err(self.eResultPrivate)

func map*[E](
    self: Result[void, E], f: proc()
): Result[void, E] {.inline, effectsOf: f.} =
  ## Call f if `self` is ok
  case self.oResultPrivate
  of true:
    f()
    result.ok()
  of false:
    when E is void:
      result.err()
    else:
      result.err(self.eResultPrivate)

func flatMap*[T0: not void, E, T1](
    self: Result[T0, E], f: proc(x: T0): Result[T1, E]
): Result[T1, E] {.inline, effectsOf: f.} =
  case self.oResultPrivate
  of true:
    f(self.vResultPrivate)
  of false:
    when E is void:
      Result[T1, void].err()
    else:
      Result[T1, E].err(self.eResultPrivate)

func flatMap*[E, T1](
    self: Result[void, E], f: proc(): Result[T1, E]
): Result[T1, E] {.inline, effectsOf: f.} =
  case self.oResultPrivate
  of true:
    f()
  of false:
    when E is void:
      Result[T1, void].err()
    else:
      Result[T1, E].err(self.eResultPrivate)

func mapErr*[T; E0: not void, E1: not void](
    self: Result[T, E0], f: proc(x: E0): E1
): Result[T, E1] {.inline, effectsOf: f.} =
  ## Transform error using f, or leave untouched
  case self.oResultPrivate
  of true:
    when T is void:
      result.ok()
    else:
      result.ok(self.vResultPrivate)
  of false:
    result.err(f(self.eResultPrivate))

func mapErr*[T; E1: not void](
    self: Result[T, void], f: proc(): E1
): Result[T, E1] {.inline, effectsOf: f.} =
  ## Transform error using f, or return value
  case self.oResultPrivate
  of true:
    when T is void:
      result.ok()
    else:
      result.ok(self.vResultPrivate)
  of false:
    result.err(f())

func mapErr*[T; E0: not void](
    self: Result[T, E0], f: proc(x: E0)
): Result[T, void] {.inline, effectsOf: f.} =
  ## Transform error using f, or return value
  case self.oResultPrivate
  of true:
    when T is void:
      result.ok()
    else:
      result.ok(self.vResultPrivate)
  of false:
    f(self.eResultPrivate)
    result.err()

func mapErr*[T](
    self: Result[T, void], f: proc()
): Result[T, void] {.inline, effectsOf: f.} =
  ## Transform error using f, or return value
  case self.oResultPrivate
  of true:
    when T is void:
      result.ok()
    else:
      result.ok(self.vResultPrivate)
  of false:
    f()
    result.err()

func mapConvert*[T0: not void, E](
    self: Result[T0, E], T1: type
): Result[T1, E] {.inline.} =
  ## Convert result value to A using an conversion
  # Would be nice if it was automatic...
  case self.oResultPrivate
  of true:
    when T1 is void:
      result.ok()
    else:
      result.ok(T1(self.vResultPrivate))
  of false:
    when E is void:
      result.err()
    else:
      result.err(self.eResultPrivate)

func mapCast*[T0: not void, E](
    self: Result[T0, E], T1: type
): Result[T1, E] {.inline.} =
  ## Convert result value to A using a cast
  ## Would be nice with nicer syntax...
  case self.oResultPrivate
  of true:
    when T1 is void:
      result.ok()
    else:
      result.ok(cast[T1](self.vResultPrivate))
  of false:
    when E is void:
      result.err()
    else:
      result.err(self.eResultPrivate)

func mapConvertErr*[T, E0](self: Result[T, E0], E1: type): Result[T, E1] {.inline.} =
  ## Convert result error to E1 using an conversion
  # Would be nice if it was automatic...
  when E0 is E1:
    result = self
  else:
    if self.oResultPrivate:
      when T is void:
        result.ok()
      else:
        result.ok(self.vResultPrivate)
    else:
      when E1 is void:
        result.err()
      else:
        result.err(E1(self.eResultPrivate))

func mapCastErr*[T, E0](self: Result[T, E0], E1: type): Result[T, E1] {.inline.} =
  ## Convert result value to A using a cast
  ## Would be nice with nicer syntax...
  if self.oResultPrivate:
    when T is void:
      result.ok()
    else:
      result.ok(self.vResultPrivate)
  else:
    result.err(cast[E1](self.eResultPrivate))

template `and`*[T0, E, T1](self: Result[T0, E], other: Result[T1, E]): Result[T1, E] =
  ## Evaluate `other` iff self.isOk, else return error
  ## fail-fast - will not evaluate other if a is an error
  let s = (self) # TODO avoid copy
  case s.oResultPrivate
  of true:
    other
  of false:
    when type(self) is type(other):
      s
    else:
      type R = type(other)
      when E is void:
        err(R)
      else:
        err(R, s.eResultPrivate)

template `or`*[T, E0, E1](self: Result[T, E0], other: Result[T, E1]): Result[T, E1] =
  ## Evaluate `other` iff `not self.isOk`, else return `self`
  ## fail-fast - will not evaluate `other` if `self` is ok
  ##
  ## ```
  ## func f(): Result[int, SomeEnum] =
  ##   f2() or err(SomeEnum.V) # Collapse errors from other module / function
  ## ```
  let s = (self) # TODO avoid copy
  case s.oResultPrivate
  of true:
    when type(self) is type(other):
      s
    else:
      type R = type(other)
      when T is void:
        ok(R)
      else:
        ok(R, s.vResultPrivate)
  of false:
    other

template orErr*[T, E0, E1](self: Result[T, E0], error: E1): Result[T, E1] =
  ## Evaluate `other` iff `not self.isOk`, else return `self`
  ## fail-fast - will not evaluate `error` if `self` is ok
  ##
  ## ```
  ## func f(): Result[int, SomeEnum] =
  ##   f2().orErr(SomeEnum.V) # Collapse errors from other module / function
  ## ```
  ##
  ## ** Experimental, may be removed **
  let s = (self) # TODO avoid copy
  type R = Result[T, E1]
  case s.oResultPrivate
  of true:
    when type(self) is R:
      s
    else:
      when T is void:
        ok(R)
      else:
        ok(R, s.vResultPrivate)
  of false:
    err(R, error)

template catch*(body: typed): Result[type(body), ref CatchableError] =
  ## Catch exceptions for body and store them in the Result
  ##
  ## ```
  ## let r = catch: someFuncThatMayRaise()
  ## ```
  type R = Result[type(body), ref CatchableError]

  try:
    when type(body) is void:
      body
      R.ok()
    else:
      R.ok(body)
  except CatchableError as eResultPrivate:
    R.err(eResultPrivate)

template capture*[E: Exception](T: type, someExceptionExpr: ref E): Result[T, ref E] =
  ## Evaluate someExceptionExpr and put the exception into a result, making sure
  ## to capture a call stack at the capture site:
  ##
  ## ```
  ## let eResultPrivate: Result[void, ValueError] = void.capture((ref ValueError)(msg: "test"))
  ## echo eResultPrivate.error().getStackTrace()
  ## ```
  type R = Result[T, ref E]

  var ret: R
  try:
    # TODO is this needed? I think so, in order to grab a call stack, but
    #      haven't actually tested...
    if true:
      # I'm sure there's a nicer way - this just works :)
      raise someExceptionExpr
  except E as caught:
    ret = R.err(caught)
  ret

func `==`*[T0: not void, E0: not void, T1: not void, E1: not void](
    lhs: Result[T0, E0], rhs: Result[T1, E1]
): bool {.inline.} =
  if lhs.oResultPrivate != rhs.oResultPrivate:
    false
  else:
    case lhs.oResultPrivate # and rhs.oResultPrivate implied
    of true:
      lhs.vResultPrivate == rhs.vResultPrivate
    of false:
      lhs.eResultPrivate == rhs.eResultPrivate

func `==`*[E0, E1](lhs: Result[void, E0], rhs: Result[void, E1]): bool {.inline.} =
  if lhs.oResultPrivate != rhs.oResultPrivate:
    false
  else:
    case lhs.oResultPrivate # and rhs.oResultPrivate implied
    of true:
      true
    of false:
      lhs.eResultPrivate == rhs.eResultPrivate

func `==`*[T0, T1](lhs: Result[T0, void], rhs: Result[T1, void]): bool {.inline.} =
  if lhs.oResultPrivate != rhs.oResultPrivate:
    false
  else:
    case lhs.oResultPrivate # and rhs.oResultPrivate implied
    of true:
      lhs.vResultPrivate == rhs.vResultPrivate
    of false:
      true

func value*[E](self: Result[void, E]) {.inline.} =
  ## Fetch value of result if set, or raise Defect
  ## Exception bridge mode: raise given Exception instead
  ## See also: Option.get
  withAssertOk(self):
    discard

func value*[T: not void, E](self: Result[T, E]): maybeLent T {.inline.} =
  ## Fetch value of result if set, or raise Defect
  ## Exception bridge mode: raise given Exception instead
  ## See also: Option.get
  withAssertOk(self):
    when T isnot void:
      # TODO: remove result usage.
      # A workaround for nim VM bug:
      # https://github.com/nim-lang/Nim/issues/22216
      result = self.vResultPrivate

func value*[T: not void, E](self: var Result[T, E]): var T {.inline.} =
  ## Fetch value of result if set, or raise Defect
  ## Exception bridge mode: raise given Exception instead
  ## See also: Option.get

  (
    block:
      withAssertOk(self):
        addr self.vResultPrivate
  )[]

template `[]`*[T: not void, E](self: Result[T, E]): T =
  ## Fetch value of result if set, or raise Defect
  ## Exception bridge mode: raise given Exception instead
  self.value()

template `[]`*[E](self: Result[void, E]) =
  ## Fetch value of result if set, or raise Defect
  ## Exception bridge mode: raise given Exception instead
  self.value()

template unsafeValue*[T: not void, E](self: Result[T, E]): T =
  ## Fetch value of result if set, undefined behavior if unset
  ## See also: `unsafeError`
  self.vResultPrivate

template unsafeValue*[E](self: Result[void, E]) =
  ## Fetch value of result if set, undefined behavior if unset
  ## See also: `unsafeError`
  assert self.oResultPrivate # Emulate field access defect in debug builds

func tryValue*[E](self: Result[void, E]) {.inline.} =
  ## Fetch value of result if set, or raise
  ## When E is an Exception, raise that exception - otherwise, raise a ResultError[E]
  mixin raiseResultError
  case self.oResultPrivate
  of false:
    self.raiseResultError()
  of true:
    discard

func tryValue*[T: not void, E](self: Result[T, E]): maybeLent T {.inline.} =
  ## Fetch value of result if set, or raise
  ## When E is an Exception, raise that exception - otherwise, raise a ResultError[E]
  mixin raiseResultError
  case self.oResultPrivate
  of false:
    self.raiseResultError()
  of true:
    # TODO https://github.com/nim-lang/Nim/issues/22216
    result = self.vResultPrivate

func expect*[E](self: Result[void, E], m: string) =
  ## Return value of Result, or raise a `Defect` with the given message - use
  ## this helper to extract the value when an error is not expected, for example
  ## because the program logic dictates that the operation should never fail
  ##
  ## ```nim
  ## let r = Result[int, int].ok(42)
  ## # Put here a helpful comment why you think this won't fail
  ## echo r.expect("r was just set to ok(42)")
  ## ```
  case self.oResultPrivate
  of false:
    when E isnot void:
      raiseResultDefect(m, self.eResultPrivate)
    else:
      raiseResultDefect(m)
  of true:
    discard

func expect*[T: not void, E](self: Result[T, E], m: string): maybeLent T =
  ## Return value of Result, or raise a `Defect` with the given message - use
  ## this helper to extract the value when an error is not expected, for example
  ## because the program logic dictates that the operation should never fail
  ##
  ## ```nim
  ## let r = Result[int, int].ok(42)
  ## # Put here a helpful comment why you think this won't fail
  ## echo r.expect("r was just set to ok(42)")
  ## ```
  case self.oResultPrivate
  of false:
    when E isnot void:
      raiseResultDefect(m, self.eResultPrivate)
    else:
      raiseResultDefect(m)
  of true:
    # TODO https://github.com/nim-lang/Nim/issues/22216
    result = self.vResultPrivate

func expect*[T: not void, E](self: var Result[T, E], m: string): var T =
  (
    case self.oResultPrivate
    of false:
      when E isnot void:
        raiseResultDefect(m, self.eResultPrivate)
      else:
        raiseResultDefect(m)
    of true:
      addr self.vResultPrivate
  )[]

func `$`*[T, E](self: Result[T, E]): string =
  ## Returns string representation of `self`
  case self.oResultPrivate
  of true:
    when T is void:
      "ok()"
    else:
      "ok(" & $self.vResultPrivate & ")"
  of false:
    when E is void:
      "none()"
    else:
      "err(" & $self.eResultPrivate & ")"

func error*[T](self: Result[T, void]) =
  ## Fetch error of result if set, or raise Defect
  case self.oResultPrivate
  of true:
    when T isnot void:
      raiseResultDefect("Trying to access error when value is set", self.vResultPrivate)
    else:
      raiseResultDefect("Trying to access error when value is set")
  of false:
    discard

func error*[T; E: not void](self: Result[T, E]): maybeLent E =
  ## Fetch error of result if set, or raise Defect
  case self.oResultPrivate
  of true:
    when T isnot void:
      raiseResultDefect("Trying to access error when value is set", self.vResultPrivate)
    else:
      raiseResultDefect("Trying to access error when value is set")
  of false:
    # TODO https://github.com/nim-lang/Nim/issues/22216
    result = self.eResultPrivate

func tryError*[T](self: Result[T, void]) {.inline.} =
  ## Fetch error of result if set, or raise
  ## Raises a ResultError[T]
  mixin raiseResultOk
  case self.oResultPrivate
  of true:
    self.raiseResultOk()
  of false:
    discard

func tryError*[T; E: not void](self: Result[T, E]): maybeLent E {.inline.} =
  ## Fetch error of result if set, or raise
  ## Raises a ResultError[T]
  mixin raiseResultOk
  case self.oResultPrivate
  of true:
    self.raiseResultOk()
  of false:
    # TODO https://github.com/nim-lang/Nim/issues/22216
    result = self.eResultPrivate

template unsafeError*[T; E: not void](self: Result[T, E]): E =
  ## Fetch error of result if set, undefined behavior if unset
  ## See also: `unsafeValue`
  self.eResultPrivate

template unsafeError*[T](self: Result[T, void]) =
  ## Fetch error of result if set, undefined behavior if unset
  ## See also: `unsafeValue`
  assert not self.oResultPrivate # Emulate field access defect in debug builds

func optValue*[T, E](self: Result[T, E]): Opt[T] =
  ## Return the value of a Result as an Opt, or none if Result is an error
  case self.oResultPrivate
  of true:
    when T is void:
      Opt[void].ok()
    else:
      Opt.some(self.vResultPrivate)
  of false:
    Opt.none(T)

func optError*[T, E](self: Result[T, E]): Opt[E] =
  ## Return the error of a Result as an Opt, or none if Result is a value
  case self.oResultPrivate
  of true:
    Opt.none(E)
  of false:
    Opt.some(self.eResultPrivate)

# Alternative spellings for `value`, for `options` compatibility
template get*[T: not void, E](self: Result[T, E]): T =
  self.value()

template get*[E](self: Result[void, E]) =
  self.value()

template tryGet*[T: not void, E](self: Result[T, E]): T =
  self.tryValue()

template tryGet*[E](self: Result[void, E]) =
  self.tryValue()

template unsafeGet*[T: not void, E](self: Result[T, E]): T =
  self.unsafeValue()

template unsafeGet*[E](self: Result[void, E]) =
  self.unsafeValue()

# `var` overloads should not be needed but result in invalid codegen (!):
# https://github.com/nim-lang/Nim/issues/22049 (fixed in 1.6.16+)
func get*[T: not void, E](self: var Result[T, E]): var T =
  self.value()

func get*[T, E](self: Result[T, E], otherwise: T): T {.inline.} =
  ## Fetch value of result if set, or return the value `otherwise`
  ## See `valueOr` for a template version that avoids evaluating `otherwise`
  ## unless necessary
  case self.oResultPrivate
  of true: self.vResultPrivate
  of false: otherwise

when resultsGenericsOpenSymWorkaround:
  import macros

  proc containsHack(n: NimNode): bool =
    if n.len == 0:
      n.eqIdent("isOkOr") or n.eqIdent("isErrOr") or n.eqIdent("valueOr") or
        n.eqIdent("errorOr")
    else:
      for child in n:
        if containsHack(child):
          return true
      false

  proc containsIdent(n: NimNode, what: string, with: NimNode): bool =
    if n == with:
      false # Don't replace if the right symbol is already being used
    elif n.eqIdent(what):
      true
    else:
      for child in n:
        if containsIdent(child, what, with):
          return true

      false

  proc replace(n: NimNode, what: string, with: NimNode): NimNode =
    if not containsIdent(n, what, with): # Fast path that avoids copies altogether
      return n

    if n == with:
      result = with
    elif n.eqIdent(what):
      when resultsGenericsOpenSymWorkaroundHint:
        hint("Replaced conflicting external symbol " & what, n)
      result = with
    else:
      case n.kind
      of nnkCallKinds:
        if n[0].containsHack():
          # Don't replace inside nested expansion
          result = n
        elif n[0].eqIdent(what):
          if n.len == 1:
            if n[0] == with:
              result = n
            else:
              # No arguments - replace call symbol
              result = copyNimNode(n)
              result.add with
              when resultsGenericsOpenSymWorkaroundHint:
                hint("Replaced conflicting external symbol " & what, n[0])
          else:
            # `error(...)` - replace args but not function name
            result = copyNimNode(n)
            result.add n[0]
            for i in 1 ..< n.len:
              result.add replace(n[i], what, with)
        else:
          result = copyNimNode(n)
          for i in 0 ..< n.len:
            result.add replace(n[i], what, with)
      of nnkExprEqExpr:
        # "error = xxx" - function call with named parameters and other weird stuff
        result = copyNimNode(n)
        result.add n[0]
        for i in 1 ..< n.len:
          result.add replace(n[i], what, with)
      of nnkLetSection, nnkVarSection, nnkFormalParams:
        result = copyNimNode(n)
        for i in 0 ..< n.len:
          result.add replace(n[i], what, with)
      of nnkDotExpr:
        # Ignore rhs in "abc.error"
        result = copyNimNode(n)
        result.add(replace(n[0], what, with))
        result.add(n[1])
      else:
        if (
          n.kind == nnkForStmt and
          (n[0].eqIdent(what) or (n.len == 4 and n[1].eqIdent(what))) or
          (n.kind == nnkIdentDefs and n[0].eqIdent(what))
        ):
          # Naming the symbol the same way requires lots of magic here - just
          # say no
          error("Shadowing variable declarations of `" & what & "` not supported", n[0])

        result = copyNimNode(n)
        for i in 0 ..< n.len:
          result.add replace(n[i], what, with)

  macro replaceHack(body, what, with: untyped): untyped =
    # This hack replaces the `what` identifier with `with` except where
    # this replacing is not expected - this is an approximation of the intent
    # of injecting a template and likely doesn't cover all applicable cases
    result = replace(body, $what, with)

  template isOkOr*[T, E](self: Result[T, E], body: untyped) =
    ## Evaluate `body` iff result has been assigned an error
    ## `body` is evaluated lazily.
    ##
    ## Example:
    ## ```
    ## let
    ##   v = Result[int, string].err("hello")
    ##   x = v.isOkOr: echo "not ok"
    ##   # experimental: direct error access using an unqualified `error` symbol
    ##   z = v.isOkOr: echo error
    ## ```
    ##
    ## `error` access:
    ##
    ## TODO experimental, might change in the future
    ##
    ## The template contains a shortcut for accessing the error of the result,
    ## it can only be used outside of generic code,
    ## see https://github.com/status-im/nim-stew/issues/161#issuecomment-1397121386

    let s = (self) # TODO avoid copy
    case s.oResultPrivate
    of false:
      when E isnot void:
        template error(): E {.used, gensym.} =
          s.eResultPrivate

        replaceHack(body, "error", error)
      else:
        body
    of true:
      discard

  template isErrOr*[T, E](self: Result[T, E], body: untyped) =
    ## Evaluate `body` iff result has been assigned a value
    ## `body` is evaluated lazily.
    ##
    ## Example:
    ## ```
    ## let
    ##   v = Result[int, string].ok(42)
    ##   x = v.isErrOr: echo "not err"
    ##   # experimental: direct value access using an unqualified `value` symbol
    ##   z = v.isErrOr: echo value
    ## ```
    ##
    ## `value` access:
    ##
    ## TODO experimental, might change in the future
    ##
    ## The template contains a shortcut for accessing the value of the result,
    ## it can only be used outside of generic code,
    ## see https://github.com/status-im/nim-stew/issues/161#issuecomment-1397121386

    let s = (self) # TODO avoid copy
    case s.oResultPrivate
    of true:
      when T isnot void:
        template value(): T {.used, gensym.} =
          s.vResultPrivate

        replaceHack(body, "value", s.vResultPrivate)
      else:
        body
    of false:
      discard

  template valueOr*[T: not void, E](self: Result[T, E], def: untyped): T =
    ## Fetch value of result if set, or evaluate `def`
    ## `def` is evaluated lazily, and must be an expression of `T` or exit
    ## the scope (for example using `return` / `raise`)
    ##
    ## See `isOkOr` for a version that works with `Result[void, E]`.
    ##
    ## Example:
    ## ```
    ## let
    ##   v = Result[int, string].err("hello")
    ##   x = v.valueOr: 42 # x == 42 now
    ##   y = v.valueOr: raise (ref ValueError)(msg: "v is an error, gasp!")
    ##   # experimental: direct error access using an unqualified `error` symbol
    ##   z = v.valueOr: raise (ref ValueError)(msg: error)
    ## ```
    ##
    ## `error` access:
    ##
    ## TODO experimental, might change in the future
    ##
    ## The template contains a shortcut for accessing the error of the result,
    ## it can only be used outside of generic code,
    ## see https://github.com/status-im/nim-stew/issues/161#issuecomment-1397121386
    ##
    let s = (self) # TODO avoid copy
    case s.oResultPrivate
    of true:
      s.vResultPrivate
    of false:
      when E isnot void:
        template error(): E {.used, gensym.} =
          s.eResultPrivate

        replaceHack(def, "error", error)
      else:
        def

  template errorOr*[T; E: not void](self: Result[T, E], def: untyped): E =
    ## Fetch error of result if not set, or evaluate `def`
    ## `def` is evaluated lazily, and must be an expression of `T` or exit
    ## the scope (for example using `return` / `raise`)
    ##
    ## See `isErrOr` for a version that works with `Result[T, void]`.
    let s = (self) # TODO avoid copy
    case s.oResultPrivate
    of false:
      s.eResultPrivate
    of true:
      when T isnot void:
        template value(): T {.used, gensym.} =
          s.vResultPrivate

        replaceHack(def, "value", value)
      else:
        def

else:
  # TODO https://github.com/nim-lang/Nim/pull/23892#discussion_r1713434311
  const pushGenericsOpenSym = defined(nimHasGenericsOpenSym2) and resultsGenericsOpenSym

  template isOkOr*[T, E](self: Result[T, E], body: untyped) =
    ## Evaluate `body` iff result has been assigned an error
    ## `body` is evaluated lazily.
    ##
    ## Example:
    ## ```
    ## let
    ##   v = Result[int, string].err("hello")
    ##   x = v.isOkOr: echo "not ok"
    ##   # experimental: direct error access using an unqualified `error` symbol
    ##   z = v.isOkOr: echo error
    ## ```
    ##
    ## `error` access:
    ##
    ## TODO experimental, might change in the future
    ##
    ## The template contains a shortcut for accessing the error of the result,
    ## it can only be used outside of generic code,
    ## see https://github.com/status-im/nim-stew/issues/161#issuecomment-1397121386

    let s = (self) # TODO avoid copy
    case s.oResultPrivate
    of false:
      when E isnot void:
        when pushGenericsOpenSym:
          {.push experimental: "genericsOpenSym".}
        template error(): E {.used.} =
          s.eResultPrivate

      body
    of true:
      discard

  template isErrOr*[T, E](self: Result[T, E], body: untyped) =
    ## Evaluate `body` iff result has been assigned a value
    ## `body` is evaluated lazily.
    ##
    ## Example:
    ## ```
    ## let
    ##   v = Result[int, string].ok(42)
    ##   x = v.isErrOr: echo "not err"
    ##   # experimental: direct value access using an unqualified `value` symbol
    ##   z = v.isErrOr: echo value
    ## ```
    ##
    ## `value` access:
    ##
    ## TODO experimental, might change in the future
    ##
    ## The template contains a shortcut for accessing the value of the result,
    ## it can only be used outside of generic code,
    ## see https://github.com/status-im/nim-stew/issues/161#issuecomment-1397121386

    let s = (self) # TODO avoid copy
    case s.oResultPrivate
    of true:
      when T isnot void:
        when pushGenericsOpenSym:
          {.push experimental: "genericsOpenSym".}
        template value(): T {.used.} =
          s.vResultPrivate

      body
    of false:
      discard

  template valueOr*[T: not void, E](self: Result[T, E], def: untyped): T =
    ## Fetch value of result if set, or evaluate `def`
    ## `def` is evaluated lazily, and must be an expression of `T` or exit
    ## the scope (for example using `return` / `raise`)
    ##
    ## See `isOkOr` for a version that works with `Result[void, E]`.
    ##
    ## Example:
    ## ```
    ## let
    ##   v = Result[int, string].err("hello")
    ##   x = v.valueOr: 42 # x == 42 now
    ##   y = v.valueOr: raise (ref ValueError)(msg: "v is an error, gasp!")
    ##   # experimental: direct error access using an unqualified `error` symbol
    ##   z = v.valueOr: raise (ref ValueError)(msg: error)
    ## ```
    ##
    ## `error` access:
    ##
    ## TODO experimental, might change in the future
    ##
    ## The template contains a shortcut for accessing the error of the result,
    ## it can only be used outside of generic code,
    ## see https://github.com/status-im/nim-stew/issues/161#issuecomment-1397121386
    ##
    let s = (self) # TODO avoid copy
    case s.oResultPrivate
    of true:
      s.vResultPrivate
    of false:
      when E isnot void:
        when pushGenericsOpenSym:
          {.push experimental: "genericsOpenSym".}
        template error(): E {.used.} =
          s.eResultPrivate

      def

  template errorOr*[T; E: not void](self: Result[T, E], def: untyped): E =
    ## Fetch error of result if not set, or evaluate `def`
    ## `def` is evaluated lazily, and must be an expression of `T` or exit
    ## the scope (for example using `return` / `raise`)
    ##
    ## See `isErrOr` for a version that works with `Result[T, void]`.
    let s = (self) # TODO avoid copy
    case s.oResultPrivate
    of false:
      s.eResultPrivate
    of true:
      when T isnot void:
        when pushGenericsOpenSym:
          {.push experimental: "genericsOpenSym".}
        template value(): T {.used.} =
          s.vResultPrivate

      def

func flatten*[T, E](self: Result[Result[T, E], E]): Result[T, E] =
  ## Remove one level of nesting
  case self.oResultPrivate
  of true:
    self.vResultPrivate
  of false:
    when E is void:
      err(Result[T, E])
    else:
      err(Result[T, E], self.error)

func filter*[T, E](
    self: Result[T, E], callback: proc(x: T): Result[void, E]
): Result[T, E] {.effectsOf: callback.} =
  ## Apply `callback` to the `self`, iff `self` is not an error. If `callback`
  ## returns an error, return that error, else return `self`

  case self.oResultPrivate
  of true:
    callback(self.vResultPrivate) and self
  of false:
    self

func filter*[E](
    self: Result[void, E], callback: proc(): Result[void, E]
): Result[void, E] {.effectsOf: callback.} =
  ## Apply `callback` to the `self`, iff `self` is not an error. If `callback`
  ## returns an error, return that error, else return `self`

  case self.oResultPrivate
  of true:
    callback() and self
  of false:
    self

func filter*[T](
    self: Result[T, void], callback: proc(x: T): bool
): Result[T, void] {.effectsOf: callback.} =
  ## Apply `callback` to the `self`, iff `self` is not an error. If `callback`
  ## returns an error, return that error, else return `self`

  case self.oResultPrivate
  of true:
    if callback(self.vResultPrivate):
      self
    else:
      Result[T, void].err()
  of false:
    self

# Options compatibility

template some*[T](O: type Opt, v: T): Opt[T] =
  ## Create an `Opt` set to a value
  ##
  ## ```
  ## let oResultPrivate = Opt.some(42)
  ## assert oResultPrivate.isSome and oResultPrivate.value() == 42
  ## ```
  Opt[T].ok(v)

template none*(O: type Opt, T: type): Opt[T] =
  ## Create an `Opt` set to none
  ##
  ## ```
  ## let oResultPrivate = Opt.none(int)
  ## assert oResultPrivate.isNone
  ## ```
  Opt[T].err()

template isSome*(oResultPrivate: Opt): bool =
  ## Alias for `isOk`
  isOk oResultPrivate

template isNone*(oResultPrivate: Opt): bool =
  ## Alias of `isErr`
  isErr oResultPrivate

# Syntactic convenience

template `?`*[T, E](self: Result[T, E]): auto =
  ## Early return - if self is an error, we will return from the current
  ## function, else we'll move on..
  ##
  ## ```
  ## let v = ? funcWithResult()
  ## echo v # prints value, not Result!
  ## ```
  ## Experimental
  # TODO the v copy is here to prevent multiple evaluations of self - could
  #      probably avoid it with some fancy macro magic..
  let v = (self)
  case v.oResultPrivate
  of false:
    # Instead of `return xxx` we use `result = xxx; return` which avoids the
    # need to rewrite `return` in macros that take over the `result` symbol and
    # its associated control flow - this hack increases compatibility with
    # chronos' async - see https://github.com/status-im/nim-stew/issues/37 for
    # more in-depth discussion.
    when typeof(result) is typeof(v):
      result = v
      return
    else:
      when E is void:
        result = err(typeof(result))
        return
      else:
        result = err(typeof(result), v.eResultPrivate)
        return
  of true:
    when not (T is void):
      v.vResultPrivate

# Collection integration

iterator values*[T, E](self: Result[T, E]): maybeLent T =
  ## Iterate over a Result as a 0/1-item collection, returning its value if set
  case self.oResultPrivate
  of true:
    yield self.vResultPrivate
  of false:
    discard

iterator errors*[T, E](self: Result[T, E]): maybeLent E =
  ## Iterate over a Result as a 0/1-item collection, returning its error if set
  case self.oResultPrivate
  of false:
    yield self.eResultPrivate
  of true:
    discard

iterator items*[T](self: Opt[T]): maybeLent T =
  ## Iterate over an Opt as a 0/1-item collection, returning its value if set
  case self.oResultPrivate
  of true:
    yield self.vResultPrivate
  of false:
    discard

iterator mvalues*[T, E](self: var Result[T, E]): var T =
  case self.oResultPrivate
  of true:
    yield self.vResultPrivate
  of false:
    discard

iterator merrors*[T, E](self: var Result[T, E]): var E =
  case self.oResultPrivate
  of false:
    yield self.eResultPrivate
  of true:
    discard

iterator mitems*[T](self: var Opt[T]): var T =
  case self.oResultPrivate
  of true:
    yield self.vResultPrivate
  of false:
    discard

func containsValue*(self: Result, v: auto): bool =
  ## Return true iff the given result is set to a value that equals `v`
  case self.oResultPrivate
  of true:
    self.vResultPrivate == v
  of false:
    false

func containsError*(self: Result, e: auto): bool =
  ## Return true iff the given result is set to an error that equals `e`
  case self.oResultPrivate
  of false:
    self.eResultPrivate == e
  of true:
    false

func contains*(self: Opt, v: auto): bool =
  ## Return true iff the given `Opt` is set to a value that equals `v` - can
  ## also be used in the "infix" `in` form:
  ##
  ## ```nim
  ## assert "value" in Opt.some("value")
  ## ```
  case self.oResultPrivate
  of true:
    self.vResultPrivate == v
  of false:
    false
