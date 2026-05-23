# Interactive ARM64 Assembly in SBCL

This note describes one practical way to assemble and run small ARM64
machine-code snippets from an SBCL REPL. It uses SBCL internals, so it is
appropriate for exploration and backend work, not for portable application
interfaces.

The basic idea is:

1. Use SBCL's internal assembler to emit ARM64 instructions into a segment.
2. Copy the assembled bytes into executable storage.
3. Flush the instruction cache.
4. Call the code through SBCL's alien function call interface.

The second half of this note ports the AMD64 article
[*SBCL: the ultimate assembly code breadboard*](sbcl-assembly-breadboard.md)
to ARM64. The VM design (a rotating-stack threaded interpreter, dispatched by
a `NEXT` sequence specialised on the compile-time stack pointer) is
unchanged. The code, however, is ARM64-natural: 32-bit `w` register views,
`ldr`/`str`, `ldp`/`stp`, `cbz`/`cbnz`, condition-suffixed `b`, and `subs`
for fused decrement-and-branch.

All numeric output below was captured on this machine: an Apple Silicon Mac
running SBCL 2.6.4. The benchmarks at the end were measured here too.

## Minimal example

This emits a function that returns the C integer `42`.

```lisp
(let* ((segment (sb-assem:make-segment))
       ;; ABI x0, not SBCL's Lisp R0 TN.
       (x0 (sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::any-reg) 0)))
  (sb-assem:assemble (segment nil)
    (sb-assem:inst mov x0 42)
    (sb-assem:inst ret))
  (sb-assem:finalize-segment segment)
  (let* ((bytes (sb-assem:segment-buffer segment))
         (code (sb-vm::make-static-code-vector (length bytes) bytes))
         (sap (sb-sys:vector-sap code)))
    (sb-alien:alien-funcall
     (sb-alien:extern-alien "os_flush_icache"
                            (function sb-alien:void
                                      sb-sys:system-area-pointer
                                      sb-alien:unsigned-long))
     sap (length bytes))
    (sb-alien:alien-funcall
     (sb-alien:sap-alien sap (function sb-alien:int)))))
```

On ARM64 this should return:

```lisp
42
```

The emitted bytes for that example are:

```lisp
(64 5 128 210 192 3 95 214)
```

## Convenience helpers

For repeated REPL work, define a small helper for ABI general-purpose
registers:

```lisp
(defun abi-gpr (n)
  (sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::any-reg) n))
```

Then the first argument/result register is `(abi-gpr 0)`, the second is
`(abi-gpr 1)`, and so on. For 32-bit views (the `w0` … `w30` form) ask for
the `32-bit-reg` storage class instead:

```lisp
(defun abi-gpr-w (n)
  (sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::32-bit-reg) n))
```

A simple wrapper for no-argument integer-returning thunks can look like
this:

```lisp
(defun call-arm64-int-thunk (emitter)
  (let ((segment (sb-assem:make-segment)))
    (sb-assem:assemble (segment nil)
      (funcall emitter))
    (sb-assem:finalize-segment segment)
    (let* ((bytes (sb-assem:segment-buffer segment))
           (code (sb-vm::make-static-code-vector (length bytes) bytes))
           (sap (sb-sys:vector-sap code)))
      (sb-alien:alien-funcall
       (sb-alien:extern-alien "os_flush_icache"
                              (function sb-alien:void
                                        sb-sys:system-area-pointer
                                        sb-alien:unsigned-long))
       sap (length bytes))
      (sb-alien:alien-funcall
       (sb-alien:sap-alien sap (function sb-alien:int))))))
```

Example use:

```lisp
(call-arm64-int-thunk
 (lambda ()
   (let ((x0 (abi-gpr 0)))
     (sb-assem:inst mov x0 42)
     (sb-assem:inst ret))))
```

## Syntax

SBCL's assembler syntax is Lisp forms, not textual ARM64 assembly. For
example:

```lisp
(sb-assem:inst mov x0 42)
(sb-assem:inst ret)
(sb-assem:inst ldr x0 (sb-vm::@ x1 8))
```

ARM64 memory operands are constructed with `(sb-vm::@ base offset
&optional :mode)`, where `:mode` is one of `:offset`, `:pre-index`, or
`:post-index`. Instruction definitions live in
`src/compiler/arm64/insts.lisp`. That file is the best reference for
accepted instruction names and operand shapes.

## Important caveats

This is internal API. Names, packages, and calling details can change
between SBCL versions.

Call generated snippets through the foreign-call ABI unless you are working
on SBCL backend internals. That means arguments and return values follow the
platform C ABI: integer results return in ABI register `x0`, the second
integer argument is `x1`, and so on.

Do not confuse ABI register numbers with SBCL's internal Lisp TN names. In
this checkout, `sb-vm::r0-tn` is not ABI `x0`; for foreign-call snippets,
create TNs with numeric offsets such as:

```lisp
(sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::any-reg) 0)
```

Do not return Lisp objects or manipulate SBCL's Lisp stack, binding stack,
thread state, or GC-visible data from raw foreign thunks unless you are
deliberately writing backend code and understand the relevant invariants.

A subtle point worth flagging up front: SBCL's ARM64 backend reserves
several registers in the otherwise callee-saved range (`x21` is
`thread-tn`, `x26` is `null-tn`, `x27` is `csp-tn`, `x28` is
`cardtable-tn`). The breadboard VM below borrows those registers for its
own use, but enters and leaves through `stp`/`ldp` pairs, so SBCL's
invariants are restored before control returns to Lisp. Inside the VM the
disassembler still prints those registers under their SBCL names
(`THREAD`, `NULL`, `CSP`, `CARDTABLE`). When reading the listings further
down, mentally substitute:

| Disassembler symbol | Numeric register | VM role |
| --- | --- | --- |
| `WR9` / `R9`         | `w19` / `x19`     | stack slot 0 (TOS at `sp=0`) |
| `WR10` / `R10`       | `w20` / `x20`     | stack slot 1 |
| `WTHREAD` / `THREAD` | `w21` / `x21`     | stack slot 2 |
| `WLEXENV` / `LEXENV` | `w22` / `x22`     | stack slot 3 |
| `WNARGS`  / `NARGS`  | `w23` / `x23`     | stack slot 4 |
| `WNFP`    / `NFP`    | `w24` / `x24`     | stack slot 5 |
| `WOCFP`   / `OCFP`   | `w25` / `x25`     | stack slot 6 |
| `WNULL`   / `NULL`   | `w26` / `x26`     | stack slot 7 |
| `CSP`                | `x27`             | primop base |
| `CARDTABLE`          | `x28`             | virtual IP |
| `CFP`                | `x29`             | stack-data SAP (saved during VM) |
| `TMP`                | `x9`              | scratch |

This naming collision is the price of getting eight 32-bit stack slots
that all live in registers; on ARM64 there is no large pool of
non-reserved callee-saved registers to use instead. The `enter` primop
saves the affected registers onto the C stack before the VM touches them,
and `leave-op` restores them, so the rest of the runtime never observes
the substitution.

For Lisp-aware inline machine code, a custom VOP is the more appropriate
long-term interface. Raw executable thunks are best for small ABI-level
experiments.

# A breadboard VM on ARM64

The rest of this note assumes the AMD64 breadboard article is open in
another window. Re-read the introduction there for the rotating-stack
motivation; what follows is the ARM64 mirror image.

## Plan

The AMD64 article uses:

- `r8d`–`r15d` for eight 32-bit stack slots,
- `rsi` for the primop base,
- `rdi` for the virtual instruction pointer,
- `rax` as scratch.

On ARM64 we want the same shape, with the following adjustments:

- Eight stack slots in `w19`–`w26` (the 32-bit views of `x19`–`x26`).
  These are callee-saved under AAPCS64, so SBCL's surrounding code stays
  intact as long as we restore them on `leave`.
- `x27` for the primop base, `x28` for the virtual IP. Both are
  callee-saved.
- `x29` for the stack-data SAP, paired with `x30` (the link register) in
  the `stp`/`ldp` save sequence.
- `x9` as scratch (the AAPCS64 scratch register; SBCL also uses this slot
  for `tmp-tn`).

ARM64 instructions are all four bytes, which simplifies code-page
arithmetic considerably compared to the AMD64 version. There is no
`emit-long-nop`; we just emit `nop` four bytes at a time when we need
padding.

There is one ARM64-specific encoding constraint. The form `add xN, xN,
#imm` only takes a 12-bit immediate, optionally shifted left by 12. To use
the shifted form for the rotation offset we need the per-rotation distance
(`*primitive-code-offset*`) to be a multiple of 4096. Setting it to 4096
(one page) is the simplest choice that satisfies the constraint and gives
each variant plenty of room.

## Boilerplate

```lisp
(require :sb-posix)

(defun x-reg (n) (sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::any-reg)     n))
(defun w-reg (n) (sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::32-bit-reg) n))

(defparameter *stack-base* 19)
(defparameter *stack-size* 8)
(defparameter *stack-pointer* 0)

(defun w@ (i) (w-reg (+ *stack-base* (mod (+ i *stack-pointer*) *stack-size*))))
(defun x@ (i) (x-reg (+ *stack-base* (mod (+ i *stack-pointer*) *stack-size*))))

(defparameter *primop-base* (x-reg 27))
(defparameter *vip*         (x-reg 28))
(defparameter *vip-w*       (w-reg 28))
(defparameter *data-sap*    (x-reg 29))
(defparameter *scratch*     (x-reg 9))
(defparameter *scratch-w*   (w-reg 9))

(defparameter *primitive-code-offset* 4096) ; must be multiple of 4096

(defstruct code-page
  (alloc 0)
  (code  (make-array *primitive-code-offset* :element-type '(unsigned-byte 8))))
```

`(w@ i)` returns the 32-bit register name for the `i`-th stack slot,
respecting the compile-time `*stack-pointer*`. `(x@ i)` returns the
corresponding 64-bit view (only `enter`/`leave` need this).

## Section-based assembly

For straight-line code we could keep using the `(sb-assem:make-segment)`
+ `(sb-assem:assemble (segment nil) ...)` shape from the minimal example
above. But for primops with internal labels (`djn2`, `ubench`) we want the
tagbody-style label handling that `sb-assem:assemble` offers. The
contract of that macro is that bare symbols inside its body become
labels, and instructions can refer to them by name.

That requires the *section* path in SBCL's assembler. The dance is short:
build a section, bind `*current-destination*` to it, run the body, and
finalise into a segment whose buffer you can copy out as bytes.

```lisp
(defun assemble-bytes (emitter)
  (let* ((section (sb-assem::make-section))
         (segment (sb-assem:make-segment)))
    (let ((sb-assem::*current-destination* section))
      (funcall emitter))
    (sb-assem::%assemble segment section)
    (sb-assem:segment-buffer segment)))
```

We will also want each rotated variant of a primop to live at the same
offset within its page. This is the role of `emit-code` in the AMD64
article. The ARM64 version is shorter because we only need 4-byte `nop`
padding:

```lisp
(defun emit-code (pages emitter)
  (let* ((alloc-start (logandc2 (+ 3 (reduce #'max pages :key #'code-page-alloc))
                                3)))
    (loop for sp below *stack-size*
          for page = (elt pages sp)
          do
          (let* ((bytes (let ((*stack-pointer* sp))
                          (assemble-bytes
                           (lambda ()
                             (sb-assem:assemble (sb-assem::*current-destination*)
                               (loop for cur = (code-page-alloc page) then (+ cur 4)
                                     while (< cur alloc-start)
                                     do (sb-assem:inst nop))
                               (funcall emitter)))))))
            (replace (code-page-code page) bytes :start1 (code-page-alloc page))
            (setf (code-page-alloc page)
                  (+ (code-page-alloc page) (length bytes)))))
    alloc-start))

(defun emit-all-code (&rest emitters)
  (let ((pages (loop repeat *stack-size*
                     for page = (make-code-page)
                     do (fill (code-page-code page) #x1F)
                     collect page)))
    (values (mapcar (lambda (e) (emit-code pages e)) emitters)
            pages)))
```

(The fill byte `#x1F` is the low byte of an ARM64 `nop`; it is harmless
to land on, since the real code overwrites it.)

## NEXT

Each primop ends with `NEXT`: load the next opcode from `[vIP]`, advance
`vIP`, add it to the primop base, optionally jump into the right rotation
page, and `br` through the result.

Some primops carry an inline operand right after the opcode (`lit`,
`inc`, `dec`). For those we still want to read the *next* opcode — i.e.
at `[vIP + 4]` — and to advance `vIP` by `4 + 4`. `emit-next` takes an
`operand-bytes` argument that handles both cases:

```lisp
(defun emit-next (&optional (operand-bytes 0))
  (sb-assem:inst ldr *scratch-w* (sb-vm::@ *vip* operand-bytes))
  (sb-assem:inst add *vip* *vip* (+ 4 operand-bytes))
  (sb-assem:inst add *scratch* *primop-base* *scratch*)
  (let ((rotation (mod *stack-pointer* *stack-size*)))
    (unless (zerop rotation)
      (sb-assem:inst add *scratch* *scratch*
                     (* rotation *primitive-code-offset*))))
  (sb-assem:inst br *scratch*))
```

## Stack primops

```lisp
(defun swap ()
  (sb-assem:inst mov *scratch-w* (w@ 0))
  (sb-assem:inst mov (w@ 0) (w@ 1))
  (sb-assem:inst mov (w@ 1) *scratch-w*)
  (emit-next))

(defun dup ()
  (decf *stack-pointer*)
  (sb-assem:inst mov (w@ 0) (w@ 1))
  (emit-next))

(defun drop (&optional (extra 0))
  (incf *stack-pointer*)
  (emit-next extra))

(defun add-op ()
  (sb-assem:inst add (w@ 1) (w@ 1) (w@ 0))
  (drop))

(defun sub-op ()
  (sb-assem:inst sub (w@ 1) (w@ 1) (w@ 0))
  (drop))
```

The AMD64 `xchg` mnemonic is convenient for `swap`, but ARM64 has no
single-instruction register exchange; we use a three-`mov` temp swap
through `w9`. `dup` and `drop` are pure pointer arithmetic at code-gen
time. `add-op`/`sub-op` write the result into the *second* element and
let `drop` adjust the rotating stack pointer.

The variant for `*stack-pointer* = 0` of `add-op` looks like this in
memory:

```
==== ADD-OP (offset 248, 24 bytes) ====
; Size: 24 bytes. Origin: #x1044E00F8
; 0F8:       9402130B         ADD WR10, WR10, WR9
; 0FC:       890340B9         LDR WTMP, [CARDTABLE]
; 100:       9C130091         ADD CARDTABLE, CARDTABLE, #4
; 104:       6903098B         ADD TMP, CSP, TMP
; 108:       29054091         ADD TMP, TMP, #1, LSL #12
; 10C:       20011FD6         BR TMP
```

(`WR9` is `w19`, our slot 0; `WR10` is `w20`, slot 1; `CARDTABLE` is
`x28`, our virtual IP; `CSP` is `x27`, the primop base; `TMP` is `x9`,
the scratch register. `add tmp, tmp, #1, lsl #12` is the rotation offset
that takes us from a sp=0 primop to its sp=1 successor — by the time
control reaches `add-op`'s `NEXT`, the stack pointer has already been
incremented by the embedded `drop`.)

The same primop at `*stack-pointer* = 1` instead does its arithmetic on
slot 1 and slot 2 (`w20` and `w21`), and its rotation displacement is `#2,
LSL #12`:

```
==== ADD-OP-SP1 (offset 4344, 24 bytes) ====
; Size: 24 bytes. Origin: #x1044E10F8
; 0F8:       B502140B         ADD WTHREAD, WTHREAD, WR10
; 0FC:       890340B9         LDR WTMP, [CARDTABLE]
; 100:       9C130091         ADD CARDTABLE, CARDTABLE, #4
; 104:       6903098B         ADD TMP, CSP, TMP
; 108:       29094091         ADD TMP, TMP, #2, LSL #12
; 10C:       20011FD6         BR TMP
```

(`WTHREAD` is `w21`, the third stack slot; the rest of the primop is
identical except for the rotation immediate.)

## Control flow

The AMD64 article uses `jcc` plus `cmov` to express conditional jumps,
and pushes the C stack for `call`/`ret`. ARM64 has compact compare-and-
branch instructions for the common "TOS is/isn't zero" tests, so we use
those directly. For the VM return stack we keep the same idea — push and
pop the saved virtual IP onto the C stack — but ARM64's stack pointer
must stay 16-byte aligned, so we pair the saved IP with `xzr` (the zero
register) using `stp`/`ldp` with pre/post-indexing.

```lisp
(defun jmp ()
  (sb-assem:inst ldrsw *scratch* (sb-vm::@ *vip*))
  (sb-assem:inst add *vip* *vip* 4)
  (sb-assem:inst add *vip* *vip* *scratch*)
  (emit-next))

(defun jnz ()
  (sb-assem:inst ldrsw *scratch* (sb-vm::@ *vip*))
  (sb-assem:inst add *vip* *vip* 4)
  (sb-assem:assemble (sb-assem::*current-destination*)
    (sb-assem:inst cbz (w@ 0) skip)
    (sb-assem:inst add *vip* *vip* *scratch*)
    skip)
  (emit-next))

(defun jz ()
  (sb-assem:inst ldrsw *scratch* (sb-vm::@ *vip*))
  (sb-assem:inst add *vip* *vip* 4)
  (sb-assem:assemble (sb-assem::*current-destination*)
    (sb-assem:inst cbnz (w@ 0) skip)
    (sb-assem:inst add *vip* *vip* *scratch*)
    skip)
  (emit-next))

(defun call-op ()
  (sb-assem:inst ldrsw *scratch* (sb-vm::@ *vip*))
  (sb-assem:inst add *vip* *vip* 4)
  (sb-assem:inst stp *vip* (x-reg 31)
                 (sb-vm::@ (x-reg 31) -16 :pre-index))
  (sb-assem:inst add *vip* *vip* *scratch*)
  (emit-next))

(defun ret-op ()
  (sb-assem:inst ldp *vip* *scratch*
                 (sb-vm::@ (x-reg 31) 16 :post-index))
  (emit-next))
```

`cbz` and `cbnz` test the entire register against zero in one
instruction, so the AMD64 `test ... ; cmov` two-step collapses into a
single ARM64 instruction plus a `b` over the IP-add. This is closer to
what the source code is actually expressing ("if TOS is zero, skip the
jump"), and shortens each conditional-branch primop noticeably.

The on-machine listing of `jnz` makes this concrete:

```
==== JNZ (offset 384, 36 bytes) ====
; Size: 36 bytes. Origin: #x1044E0180
; 80:       890380B9         LDRSW WTMP, [CARDTABLE]
; 84:       9C130091         ADD CARDTABLE, CARDTABLE, #4
; 88:       530000B4         CBZ R9, L0
; 8C:       9C03098B         ADD CARDTABLE, CARDTABLE, TMP
; 90: L0:   890340B9         LDR WTMP, [CARDTABLE]
; 94:       9C130091         ADD CARDTABLE, CARDTABLE, #4
; 98:       6903098B         ADD TMP, CSP, TMP
; 9C:       20011FD6         BR TMP
; A0:       1F2003D5         NOP
```

`cbz r9, L0` — "if `x19` is zero, branch over the IP-add" — is what we
want for *jump if non-zero*: when TOS is zero we *skip* the relative
jump.

## Literals, increment, decrement

```lisp
(defun lit ()
  (decf *stack-pointer*)
  (sb-assem:inst ldr (w@ 0) (sb-vm::@ *vip*))
  (emit-next 4))

(defun inc-op ()
  (sb-assem:inst ldr *scratch-w* (sb-vm::@ *vip*))
  (sb-assem:inst add (w@ 0) (w@ 0) *scratch-w*)
  (emit-next 4))

(defun dec-op ()
  (sb-assem:inst ldr *scratch-w* (sb-vm::@ *vip*))
  (sb-assem:inst sub (w@ 0) (w@ 0) *scratch-w*)
  (emit-next 4))
```

`emit-next 4` reads the next opcode from `[vIP + 4]`, leaving the inline
operand at `[vIP]` undisturbed for the current primop's `ldr`. The `lit`
listing demonstrates this; note that after `decf` of `*stack-pointer*`
the new TOS is slot 7 (`w26`, here `WNULL`):

```
==== LIT (offset 148, 24 bytes) ====
; Size: 24 bytes. Origin: #x1044E0094
; 94:       9A0340B9         LDR WNULL, [CARDTABLE]
; 98:       890740B9         LDR WTMP, [CARDTABLE, #4]
; 9C:       9C230091         ADD CARDTABLE, CARDTABLE, #8
; A0:       6903098B         ADD TMP, CSP, TMP
; A4:       291D4091         ADD TMP, TMP, #7, LSL #12
; A8:       20011FD6         BR TMP
```

Six instructions, twenty-four bytes. The `ADD TMP, TMP, #7, LSL #12`
takes us from the sp=0 page into the sp=7 page that contains the next
primop's variant.

## Decrement-and-branch

`djn` mirrors the AMD64 version: subtract one, branch over the
displacement if the result is zero. The ARM64 idiom is even tighter for
the fused form `djn2`: `subs` writes flags directly, so a single `b :eq`
takes us to the fall-through path without a separate compare.

```lisp
(defun djn ()
  (sb-assem:inst ldrsw *scratch* (sb-vm::@ *vip*))
  (sb-assem:inst add *vip* *vip* 4)
  (sb-assem:inst sub (w@ 0) (w@ 0) 1)
  (sb-assem:assemble (sb-assem::*current-destination*)
    (sb-assem:inst cbz (w@ 0) skip)
    (sb-assem:inst add *vip* *vip* *scratch*)
    skip)
  (emit-next))

(defun djn2 ()
  (sb-assem:assemble (sb-assem::*current-destination*)
    (sb-assem:inst subs (w@ 0) (w@ 0) 1)
    (sb-assem:inst b :eq fallthrough)
    (sb-assem:inst ldrsw *scratch* (sb-vm::@ *vip*))
    (sb-assem:inst add *vip* *vip* 4)
    (sb-assem:inst add *vip* *vip* *scratch*)
    (emit-next)
    fallthrough
    (sb-assem:inst add *vip* *vip* 4)
    (emit-next)))

(defun ubench ()
  (sb-assem:assemble (sb-assem::*current-destination*)
    head
    (sb-assem:inst subs (w@ 0) (w@ 0) 1)
    (sb-assem:inst b :ne head)
    (emit-next)))
```

`djn2` gets two separate `NEXT` sequences, one for each branch. The
disassembly shows the structure clearly:

```
==== DJN2 (offset 496, 64 bytes) ====
; Size: 64 bytes. Origin: #x1044E01F0
; 1F0:       73060071         SUBS WR9, WR9, #1
; 1F4:       00010054         BEQ L0
; 1F8:       890380B9         LDRSW WTMP, [CARDTABLE]
; 1FC:       9C130091         ADD CARDTABLE, CARDTABLE, #4
; 200:       9C03098B         ADD CARDTABLE, CARDTABLE, TMP
; 204:       890340B9         LDR WTMP, [CARDTABLE]
; 208:       9C130091         ADD CARDTABLE, CARDTABLE, #4
; 20C:       6903098B         ADD TMP, CSP, TMP
; 210:       20011FD6         BR TMP
; 214: L0:   9C130091         ADD CARDTABLE, CARDTABLE, #4
; 218:       890340B9         LDR WTMP, [CARDTABLE]
; 21C:       9C130091         ADD CARDTABLE, CARDTABLE, #4
; 220:       6903098B         ADD TMP, CSP, TMP
; 224:       20011FD6         BR TMP
```

The two indirect branches are 28 bytes apart, giving the branch predictor
two distinct dispatch sites.

`ubench` is the open-coded assembly comparison. `subs ... #1` plus
`b :ne head` is exactly the ARM64 idiomatic "decrement and loop if not
zero":

```
==== UBENCH (offset 620, 24 bytes) ====
; Size: 24 bytes. Origin: #x1044E026C
; 6C: L0:   73060071         SUBS WR9, WR9, #1
; 70:       E1FFFF54         BNE L0
; 74:       890340B9         LDR WTMP, [CARDTABLE]
; 78:       9C130091         ADD CARDTABLE, CARDTABLE, #4
; 7C:       6903098B         ADD TMP, CSP, TMP
; 80:       20011FD6         BR TMP
```

Just two instructions in the loop. After it finishes we still have to do
`NEXT` once to dispatch into `leave-op`.

## Enter and leave

Entering the VM is conceptually the same as on AMD64: save the
callee-saved registers we are about to clobber, copy the eight stack
slots in from the caller's data buffer, set up the primop base and
virtual IP, and dispatch into the first instruction. Leaving reverses
the sequence.

ARM64's `stp`/`ldp` lets us do six register-pair pushes/pops where AMD64
needs eight separate `push`/`pop` instructions, and the pre/post-indexed
addressing modes keep the C stack pointer 16-byte aligned for free.

```lisp
(defun enter ()
  (sb-assem:inst stp (x-reg 19) (x-reg 20) (sb-vm::@ (x-reg 31) -16 :pre-index))
  (sb-assem:inst stp (x-reg 21) (x-reg 22) (sb-vm::@ (x-reg 31) -16 :pre-index))
  (sb-assem:inst stp (x-reg 23) (x-reg 24) (sb-vm::@ (x-reg 31) -16 :pre-index))
  (sb-assem:inst stp (x-reg 25) (x-reg 26) (sb-vm::@ (x-reg 31) -16 :pre-index))
  (sb-assem:inst stp (x-reg 27) (x-reg 28) (sb-vm::@ (x-reg 31) -16 :pre-index))
  (sb-assem:inst stp (x-reg 29) (x-reg 30) (sb-vm::@ (x-reg 31) -16 :pre-index))
  (sb-assem:inst mov *data-sap* (x-reg 0))
  (sb-assem:inst mov *primop-base* (x-reg 2))
  (sb-assem:inst mov *vip* (x-reg 1))
  (loop for i below *stack-size* do
        (sb-assem:inst ldr (w@ i) (sb-vm::@ (x-reg 0) (* 4 i))))
  (emit-next))

(defun leave-op ()
  (loop for i below *stack-size* do
        (sb-assem:inst str (w@ i) (sb-vm::@ *data-sap* (* 4 i))))
  (sb-assem:inst ldp (x-reg 29) (x-reg 30) (sb-vm::@ (x-reg 31) 16 :post-index))
  (sb-assem:inst ldp (x-reg 27) (x-reg 28) (sb-vm::@ (x-reg 31) 16 :post-index))
  (sb-assem:inst ldp (x-reg 25) (x-reg 26) (sb-vm::@ (x-reg 31) 16 :post-index))
  (sb-assem:inst ldp (x-reg 23) (x-reg 24) (sb-vm::@ (x-reg 31) 16 :post-index))
  (sb-assem:inst ldp (x-reg 21) (x-reg 22) (sb-vm::@ (x-reg 31) 16 :post-index))
  (sb-assem:inst ldp (x-reg 19) (x-reg 20) (sb-vm::@ (x-reg 31) 16 :post-index))
  (sb-assem:inst ret))
```

The convention this expects from the caller: `x0` holds the SAP of an
8-element `(unsigned-byte 32)` data buffer (initial stack contents in,
final stack contents out), `x1` holds the SAP of the bytecode, `x2`
holds the SAP of the primop base. The caller must `bl` (or
`alien-funcall`) into the `enter` offset of the code page, not into
arbitrary bytecode.

The disassembled `enter` shows the saves and the inline stack-copy:

```
==== ENTER (offset 0, 88 bytes) ====
; Size: 88 bytes. Origin: #x1044E0000
; 00:       F353BFA9         STP R9, R10, [NSP, #-16]!
; 04:       F55BBFA9         STP THREAD, LEXENV, [NSP, #-16]!
; 08:       F763BFA9         STP NARGS, NFP, [NSP, #-16]!
; 0C:       F96BBFA9         STP OCFP, NULL, [NSP, #-16]!
; 10:       FB73BFA9         STP CSP, CARDTABLE, [NSP, #-16]!
; 14:       FD7BBFA9         STP CFP, LR, [NSP, #-16]!
; 18:       FD0300AA         MOV CFP, NL0
; 1C:       FB0302AA         MOV CSP, NL2
; 20:       FC0301AA         MOV CARDTABLE, NL1
; 24:       130040B9         LDR WR9, [NL0]
; 28:       140440B9         LDR WR10, [NL0, #4]
; 2C:       150840B9         LDR WTHREAD, [NL0, #8]
; 30:       160C40B9         LDR WLEXENV, [NL0, #12]
; 34:       171040B9         LDR WNARGS, [NL0, #16]
; 38:       181440B9         LDR WNFP, [NL0, #20]
; 3C:       191840B9         LDR WOCFP, [NL0, #24]
; 40:       1A1C40B9         LDR WNULL, [NL0, #28]
; 44:       890340B9         LDR WTMP, [CARDTABLE]
; 48:       9C130091         ADD CARDTABLE, CARDTABLE, #4
; 4C:       6903098B         ADD TMP, CSP, TMP
; 50:       20011FD6         BR TMP
; 54:       1F2003D5         NOP
```

Note that the AMD64 article uses a small VOP wrapper to push/pop the
stack registers around its `enter` call. We do not need that on ARM64:
because all eight `r19`–`r26` registers are AAPCS callee-saved, an
ordinary `alien-funcall` into `enter` is enough. The `stp`/`ldp` pairs
inside `enter`/`leave` themselves discharge the callee-save obligation.

## Building the code page

Static-space code vectors are size-limited on Apple Silicon SBCL (each
allocation pads up to roughly 64x its requested size). The eight
rotation-page worth of code we emit easily exhausts that budget, so
instead of `make-static-code-vector` we use anonymous JIT-flagged `mmap`
plus a small C runtime helper to copy bytes through MAP_JIT's
write-protect flip. The helper, `jit_memcpy`, ships with SBCL's runtime
(`src/runtime/arm64-darwin-os.c`); it handles the
`pthread_jit_write_protect_np` toggle internally and is safe to call
from Lisp without further dancing.

```lisp
(defun mmap-jit (size)
  (sb-posix:mmap nil size
                 (logior sb-posix:prot-read sb-posix:prot-write sb-posix:prot-exec)
                 (logior sb-posix:map-anon sb-posix:map-private #x800)
                 -1 0))

(defun jit-memcpy (dst-sap src-bytes)
  (sb-sys:with-pinned-objects (src-bytes)
    (sb-alien:alien-funcall
     (sb-alien:extern-alien "jit_memcpy"
                            (function sb-alien:void
                                      sb-sys:system-area-pointer
                                      sb-sys:system-area-pointer
                                      sb-alien:unsigned-long))
     dst-sap (sb-sys:vector-sap src-bytes) (length src-bytes))))

(defun flush-icache (sap n)
  (sb-alien:alien-funcall
   (sb-alien:extern-alien "os_flush_icache"
                          (function sb-alien:void
                                    sb-sys:system-area-pointer
                                    sb-alien:unsigned-long))
   sap n))
```

The flag `#x800` is `MAP_JIT` from `<sys/mman.h>`. SBCL's `sb-posix`
does not name-export it on this version, so we pass the literal value.

`build-code-page` glues it all together:

```lisp
(defparameter *primops*
  '(enter leave-op lit
    swap dup drop
    add-op sub-op inc-op dec-op
    jmp jnz jz djn djn2
    call-op ret-op
    ubench))

(defparameter *primops-offsets* nil)
(defparameter *code-sap* nil)

(defun build-code-page ()
  (multiple-value-bind (offsets pages) (apply 'emit-all-code *primops*)
    (let* ((total (* *stack-size* *primitive-code-offset*))
           (bytes (make-array total :element-type '(unsigned-byte 8)
                                    :initial-element 0)))
      (loop for page in pages
            for offset upfrom 0 by *primitive-code-offset*
            do (replace bytes (code-page-code page) :start1 offset))
      (let ((sap (mmap-jit total)))
        (jit-memcpy sap bytes)
        (flush-icache sap total)
        (setf *primops-offsets* (mapcar #'cons *primops* offsets)
              *code-sap* sap)))))

(build-code-page)
```

After running this, `*primops-offsets*` reports where each primop's
sp=0 variant begins inside the code page:

```lisp
((ENTER . 0) (LEAVE-OP . 88) (LIT . 148) (SWAP . 172) (DUP . 204)
 (DROP . 228) (ADD-OP . 248) (SUB-OP . 272) (INC-OP . 296)
 (DEC-OP . 324) (JMP . 352) (JNZ . 384) (JZ . 420) (DJN . 456)
 (DJN2 . 496) (CALL-OP . 560) (RET-OP . 596) (UBENCH . 620))
```

## Driving the VM from Lisp

```lisp
(defun assemble-bytecode (opcodes)
  (let ((bytes (make-array (length opcodes) :element-type '(unsigned-byte 32))))
    (loop for op in opcodes
          for i from 0
          do (setf (aref bytes i)
                   (cond ((integerp op) (ldb (byte 32 0) op))
                         ((symbolp op)
                          (or (cdr (assoc op *primops-offsets*))
                              (error "Unknown primop ~A" op)))
                         (t (error "Bad opcode ~A" op)))))
    bytes))

(defun vm (initial-stack opcodes)
  (let* ((stack (make-array *stack-size* :element-type '(unsigned-byte 32)
                                          :initial-element 0))
         (bytecode (assemble-bytecode opcodes)))
    (loop for v in (subseq (append initial-stack
                                   (make-list *stack-size* :initial-element 0))
                           0 *stack-size*)
          for i from 0
          do (setf (aref stack i) (ldb (byte 32 0) v)))
    (sb-sys:with-pinned-objects (stack bytecode)
      (let* ((stack-sap    (sb-sys:vector-sap stack))
             (bytecode-sap (sb-sys:vector-sap bytecode))
             (code-base    *code-sap*)
             (enter-off    (cdr (assoc 'enter *primops-offsets*)))
             (entry-sap    (sb-sys:sap+ code-base enter-off)))
        (sb-alien:alien-funcall
         (sb-alien:sap-alien entry-sap
                             (function sb-alien:void
                                       sb-sys:system-area-pointer
                                       sb-sys:system-area-pointer
                                       sb-alien:unsigned-long))
         stack-sap bytecode-sap code-base)))
    stack))
```

Notice the asymmetry with the AMD64 article: there is no
`%enter-vm` VOP. Because we save and restore all of `r19`–`r28` inside
`enter`/`leave`, the caller can use the standard `sap-alien` foreign-
function call interface. The platform ABI guarantees that those
registers are restored before control returns to Lisp; the VM itself
discharges that obligation.

The familiar smoke test (`add` then `sub` then `leave`):

```lisp
(vm '(3 2 10) '(add-op sub-op leave-op))
;; => #(5 0 0 0 0 0 3 5)
```

Top-of-stack is `5`, matching `10 - (3 + 2)` and the AMD64 article's
result.

## Benchmarks

All numbers below are real, captured on this machine (Apple Silicon Mac,
SBCL 2.6.4) at one hundred million iterations per loop:

```
lit/sub/jnz   0.128 s   100 Mloops   →  ~1.28 ns/iter
dec/jnz       0.101 s   100 Mloops   →  ~1.01 ns/iter
djn           0.075 s   100 Mloops   →  ~0.75 ns/iter
djn2          0.075 s   100 Mloops   →  ~0.75 ns/iter
ubench        0.024 s   100 Mloops   →  ~0.24 ns/iter
```

(Captured with `(time (vm '(100000000) '(<bytecode> leave-op)))` for
each row.)

The relative shape matches the AMD64 article's narrative: each level of
specialisation buys back roughly the same fraction of overhead. `djn`
already removes the inline literal load and the separate compare;
`djn2`'s split-`NEXT` form did not improve matters further on this
microarchitecture, presumably because the indirect branch predictor on
Apple Silicon was already happy with the single-site `djn`. `ubench` —
just `subs` plus `b :ne` plus a single trailing `NEXT` — runs about 3x
as fast as the cheapest specialised primop and around 5x as fast as the
most general `lit`/`sub`/`jnz` interpreter loop. The unsplit AMD64
article observed roughly 6x for `djn2` vs. native; the gap is narrower
on ARM64 here, with the cheapest primop within ~3x of the open-coded
loop.

## Verdict

The rotating-stack design ports cleanly to ARM64. ARM64's three-operand
arithmetic, compare-and-branch, paired load/store, and uniform 4-byte
encoding all simplify the implementation compared to the AMD64 original;
the only real friction was paying for executable memory on Apple
Silicon (MAP_JIT plus `jit_memcpy`) and arranging the code-page offset
to fit ARM64's add-immediate encoding.

What's surprising is how thin the eventual code is: the busiest primop
in the VM (`enter`) is 88 bytes, every dispatch is six instructions, and
the open-coded loop has no overhead beyond `subs`, `b :ne`, and one
trailing `NEXT`. SBCL's assembler is happy to emit any of it at the
REPL, and the section path makes named labels ergonomic, which is what
makes the breadboard worth using.

The full code shown above is in
[`scratch/04-vm-ffi.lisp`](../scratch/04-vm-ffi.lisp).
