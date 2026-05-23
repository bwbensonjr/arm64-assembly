;;;; arm64-asm.lisp -- A small SBCL library for assembling and running
;;;; ARM64 machine code from the REPL.
;;;;
;;;; This is the general-purpose runtime extracted from
;;;; doc/ARM64-ASSEMBLY.md, packaged as a library.  The package
;;;; re-exports a few SBCL internal symbols (sb-assem:inst,
;;;; sb-assem:assemble, sb-vm::@) so that callers can stay in the
;;;; ARM64-ASM package while writing assembler forms.
;;;;
;;;; Requires SBCL 2.6.4 on darwin-arm64.  Names that come from
;;;; sb-c, sb-vm, sb-assem, and sb-alien are internal to SBCL and may
;;;; change between versions.

(require :sb-posix)

(defpackage #:arm64-asm
  (:nicknames #:a64)
  (:use #:cl)
  (:import-from #:sb-assem #:inst #:assemble)
  (:import-from #:sb-vm #:@)
  (:export
   ;; Re-exports of SBCL internals
   #:inst #:assemble #:@
   ;; Register TN constructors
   #:x-tn #:w-tn
   ;; Assembly
   #:assemble-bytes
   #:assemble-section-bytes
   ;; Installation / runtime helpers
   #:install-static-code
   #:mmap-jit
   #:jit-memcpy
   #:flush-icache
   ;; High-level thunk caller
   #:call-int-thunk))

(in-package #:arm64-asm)

;;;; --- Register TN constructors --------------------------------------------

(defun x-tn (n)
  "Return a 64-bit ABI general-purpose register TN for Xn (0..30).
Use this for first-class ARM64 register references in INST forms.  The
returned TN is *not* the same as SBCL's internal Lisp-side TNs (e.g.
SB-VM::R0-TN), which use a different numbering.  For foreign-call
snippets, this constructor is the right interface."
  (sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::any-reg) n))

(defun w-tn (n)
  "Return the 32-bit (Wn) view of ABI general-purpose register n."
  (sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::32-bit-reg) n))

;;;; --- Assembly ------------------------------------------------------------

(defun assemble-bytes (emitter)
  "Run EMITTER inside a fresh SB-ASSEM segment, finalize, and return the
assembled bytes as an (UNSIGNED-BYTE 8) vector.  EMITTER is a thunk
that issues SB-ASSEM:INST forms.  Use this for straight-line snippets
that do not need named labels."
  (let ((segment (sb-assem:make-segment)))
    (sb-assem:assemble (segment nil)
      (funcall emitter))
    (sb-assem:finalize-segment segment)
    (sb-assem:segment-buffer segment)))

(defun assemble-section-bytes (emitter)
  "Like ASSEMBLE-BYTES, but binds SB-ASSEM::*CURRENT-DESTINATION* to a
fresh section so that EMITTER can use SB-ASSEM:ASSEMBLE blocks with
tagbody-style named labels.  Inside EMITTER, write

    (sb-assem:assemble (sb-assem::*current-destination*)
      (sb-assem:inst cbz w0 done)
      ...
      done)

to introduce and reference labels."
  (let* ((section (sb-assem::make-section))
         (segment (sb-assem:make-segment)))
    (let ((sb-assem::*current-destination* section))
      (funcall emitter))
    (sb-assem::%assemble segment section)
    (sb-assem:segment-buffer segment)))

;;;; --- Runtime helpers (alien wrappers) ------------------------------------

(defun flush-icache (sap nbytes)
  "Flush the data and instruction caches over [SAP, SAP+NBYTES).  This
is mandatory on ARM64 after writing executable bytes; without it the
CPU may execute stale instructions."
  (sb-alien:alien-funcall
   (sb-alien:extern-alien "os_flush_icache"
                          (function sb-alien:void
                                    sb-sys:system-area-pointer
                                    sb-alien:unsigned-long))
   sap nbytes))

(defun jit-memcpy (dst-sap src-bytes)
  "Copy SRC-BYTES (an octet vector) into DST-SAP through MAP_JIT's
write-protect flip.  The destination must come from MMAP-JIT.  Pins
SRC-BYTES while the alien call runs."
  (sb-sys:with-pinned-objects (src-bytes)
    (sb-alien:alien-funcall
     (sb-alien:extern-alien "jit_memcpy"
                            (function sb-alien:void
                                      sb-sys:system-area-pointer
                                      sb-sys:system-area-pointer
                                      sb-alien:unsigned-long))
     dst-sap (sb-sys:vector-sap src-bytes) (length src-bytes))))

(defun mmap-jit (size)
  "Allocate SIZE bytes of MAP_JIT memory (PROT_READ|WRITE|EXEC,
MAP_ANON|MAP_PRIVATE|MAP_JIT) and return the SAP.  MAP_JIT (#x800) is
required on Apple Silicon for executable user-mode allocations larger
than the static-code-vector budget."
  (sb-posix:mmap nil size
                 (logior sb-posix:prot-read
                         sb-posix:prot-write
                         sb-posix:prot-exec)
                 (logior sb-posix:map-anon
                         sb-posix:map-private
                         #x800)
                 -1
                 0))

;;;; --- Static-space installation -------------------------------------------

(defun install-static-code (bytes)
  "Copy BYTES (an (UNSIGNED-BYTE 8) vector) into a fresh static-space
code vector, flush the instruction cache, and return
  (VALUES SAP CODE-VECTOR).
The caller must retain CODE-VECTOR for as long as it intends to invoke
SAP.  Static code vectors are size-limited on Apple Silicon SBCL; for
larger allocations use MMAP-JIT plus JIT-MEMCPY."
  (let* ((code (sb-vm::make-static-code-vector (length bytes) bytes))
         (sap (sb-sys:vector-sap code)))
    (flush-icache sap (length bytes))
    (values sap code)))

;;;; --- Thunk caller --------------------------------------------------------

(defun call-int-thunk (emitter)
  "Assemble EMITTER as a no-argument int-returning thunk, install it in
static code memory, call it through the C ABI, and return the integer
result.  The caller's emitter must end with an ARM64 RET that matches
the C ABI (return value in X0/W0).

EMITTER is run through ASSEMBLE-SECTION-BYTES, so it may use bare-
symbol labels inside (SB-ASSEM:ASSEMBLE (SB-ASSEM::*CURRENT-DESTINATION*) ...)
blocks."
  (let ((bytes (assemble-section-bytes emitter)))
    (multiple-value-bind (sap code) (install-static-code bytes)
      (declare (ignore code))
      (sb-alien:alien-funcall
       (sb-alien:sap-alien sap (function sb-alien:int))))))
