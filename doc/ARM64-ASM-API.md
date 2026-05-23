# `arm64-asm`: an SBCL ARM64 assembler library

`lib/arm64-asm.lisp` packages the general-purpose helpers from
[`doc/ARM64-ASSEMBLY.md`](ARM64-ASSEMBLY.md) into a single Common Lisp
file with its own package, `ARM64-ASM` (nickname `A64`). It is a thin
wrapper over SBCL's internal assembler: it does not invent a new
syntax, it just packages enough scaffolding that an interactive user
can emit ARM64 instructions, install them in executable memory, and
call them through the C ABI without retyping the SBCL-internal
incantations.

This is internal-API code. Names that come from `sb-c`, `sb-vm`,
`sb-assem`, and `sb-alien` can change between SBCL versions; the
library has been exercised on SBCL 2.6.4 / Apple Silicon.

## Loading

```lisp
(load "lib/arm64-asm.lisp")
(use-package :arm64-asm) ; or :a64
```

The file `(require :sb-posix)`s on load.

## Package surface

The `ARM64-ASM` package re-exports three SBCL internals so the user
does not have to write `sb-assem:` and `sb-vm::` package qualifiers
when issuing assembler forms:

| Exported | Source | Purpose |
| --- | --- | --- |
| `inst` | `sb-assem:inst` | Emit one ARM64 instruction. |
| `assemble` | `sb-assem:assemble` | Begin a labelled assembly block. |
| `@` | `sb-vm::@` | Build an ARM64 memory operand. |

The library's own exports fall into four small groups: register TN
constructors, assembly drivers, runtime helpers, and a high-level
thunk caller.

## Register TN constructors

```lisp
(a64:x-tn n) ; => 64-bit ABI register Xn
(a64:w-tn n) ; => 32-bit ABI register Wn
```

These wrap `(sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::any-reg) n)`
and the `32-bit-reg` storage class, respectively. They produce TNs
keyed on numeric ABI register offsets, **not** on SBCL's named TNs:
`(a64:x-tn 0)` is the C-ABI `x0`, whereas `sb-vm::r0-tn` is something
else entirely on this backend. Use these for any code that will be
called through the foreign-call ABI.

## Assembly

### `(assemble-bytes emitter)`

`emitter` is a thunk. The library opens a fresh `sb-assem:make-segment`,
binds the segment as the assembly destination, calls `emitter`,
finalises, and returns the assembled bytes as a fresh
`(unsigned-byte 8)` vector.

Use this for straight-line code that does not need named labels:

```lisp
(a64:assemble-bytes
 (lambda ()
   (a64:inst mov (a64:x-tn 0) 42)
   (a64:inst ret)))
;; => #(64 5 128 210 192 3 95 214)
```

### `(assemble-section-bytes emitter)`

Identical in shape to `assemble-bytes`, but it binds
`sb-assem::*current-destination*` to a fresh *section* rather than a
plain segment. Inside `emitter` you can use the labelled form of
`sb-assem:assemble`:

```lisp
(a64:assemble-section-bytes
 (lambda ()
   (a64:assemble (sb-assem::*current-destination*)
     (a64:inst cbz (a64:w-tn 0) done)
     (a64:inst mov (a64:w-tn 0) 1)
     done
     (a64:inst ret))))
```

Bare symbols inside the inner `assemble` block are interpreted as
labels (per `sb-assem:assemble`'s contract).

## Runtime helpers

### `(flush-icache sap nbytes)`

Calls SBCL's runtime `os_flush_icache` over `[sap, sap+nbytes)`.
Mandatory on ARM64 after writing executable bytes.

### `(jit-memcpy dst-sap src-bytes)`

Calls SBCL's runtime `jit_memcpy` to copy `src-bytes` (an octet
vector) into `dst-sap`. `jit_memcpy` flips Apple Silicon's MAP_JIT
write-protect for you. Use this only with destinations that came from
`mmap-jit`.

### `(mmap-jit size)`

`mmap` of `size` bytes with `PROT_READ|PROT_WRITE|PROT_EXEC` and
`MAP_ANON|MAP_PRIVATE|MAP_JIT`. `MAP_JIT` is `#x800`, passed as a
literal because `sb-posix` does not name-export the flag on this SBCL
version. Returns the SAP.

### `(install-static-code bytes)` → `(values sap vector)`

Copies `bytes` into a fresh `sb-vm::make-static-code-vector`, flushes
the instruction cache, and returns both the executable SAP and the
underlying code vector. The caller must keep the vector alive for as
long as it intends to invoke the SAP. Static code vectors are
size-limited on Apple Silicon SBCL (allocations are padded by ~64x);
for larger code use `mmap-jit` + `jit-memcpy` + `flush-icache`.

## Thunk caller

### `(call-int-thunk emitter)`

A complete one-shot pipeline for the simplest case: a no-argument,
integer-returning ARM64 thunk. Internally:

1. Assemble `emitter` into bytes via `assemble-section-bytes` (so the
   emitter is allowed to use named labels).
2. Install the bytes via `install-static-code` (icache flush included).
3. Call the resulting SAP through `(sb-alien:sap-alien sap (function sb-alien:int))`.
4. Return the integer result.

The caller's emitter must end with `(a64:inst ret)` and place its
return value in `x0` / `w0` per AAPCS64.

```lisp
(a64:call-int-thunk
 (lambda ()
   (let ((x0 (a64:x-tn 0)))
     (a64:inst mov x0 42)
     (a64:inst ret))))
;; => 42
```

For thunks that take arguments or return non-integer values, drop down
to `assemble-bytes` + `install-static-code` and call the SAP through
your own `sap-alien` form with the right `(function ...)` signature.

## Memory operands

ARM64 memory operands are constructed with the re-exported `@`:

```lisp
(a64:inst ldr w0 (a64:@ x1))            ; [x1]
(a64:inst ldr w0 (a64:@ x1 8))          ; [x1, #8]
(a64:inst ldr w0 (a64:@ x1 8 :pre-index))  ; [x1, #8]!
(a64:inst str w0 (a64:@ x1 8 :post-index)) ; [x1], #8
```

The signature is `(@ base &optional (offset 0) (mode :offset))`.
`mode` is one of `:offset`, `:pre-index`, or `:post-index`.

## Cookbook

### Two-argument integer thunk (sum two i32s)

```lisp
(let* ((bytes (a64:assemble-bytes
               (lambda ()
                 (a64:inst add (a64:w-tn 0) (a64:w-tn 0) (a64:w-tn 1))
                 (a64:inst ret)))))
  (multiple-value-bind (sap code) (a64:install-static-code bytes)
    (declare (ignore code))
    (sb-alien:alien-funcall
     (sb-alien:sap-alien sap (function sb-alien:int
                                       sb-alien:int
                                       sb-alien:int))
     17 25)))
;; => 42
```

### Loop with a label

```lisp
(a64:call-int-thunk
 (lambda ()
   (let ((w0 (a64:w-tn 0))
         (w1 (a64:w-tn 1)))
     (a64:inst mov w0 0)
     (a64:inst mov w1 100)
     (a64:assemble (sb-assem::*current-destination*)
       loop
       (a64:inst add w0 w0 w1)
       (a64:inst subs w1 w1 1)
       (a64:inst b :ne loop))
     (a64:inst ret))))
;; => 5050
```

(Sums 1..100 in a register-only loop.)

## What the library does *not* cover

The breadboard-VM-specific pieces from `doc/ARM64-ASSEMBLY.md` —
rotating-stack page layout, `emit-next`, `enter`/`leave`, and the
primop catalogue — are deliberately not exported. They are part of
the *application* in that document, not part of the general-purpose
runtime. They are kept in `scratch/04-vm-ffi.lisp` as a worked
example.

## Caveats

- Internal API. SBCL 2.6.4 only.
- The `MAP_JIT` flag is hardcoded to `#x800`; `sb-posix` does not
  name-export it on this version.
- The library does no bookkeeping for static code vectors or JIT
  pages; it returns SAPs (and, for static vectors, the underlying
  vector) and lets the caller decide how long to retain them.
- For Lisp-aware inline machine code, the appropriate long-term
  interface is a custom VOP, not raw foreign thunks; use this
  library for ABI-level experiments and for porting the breadboard
  technique.
