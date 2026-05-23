;;;; Phase C: full VM with enter/leave/jmp/call/ret + end-to-end smoke test.
(require :sb-posix)
;;;;
;;;; Register usage:
;;;;   x19..x26 : stack slots (w19..w26 = 32-bit views)
;;;;   x27      : primop base (callee-saved)
;;;;   x28      : virtual IP  (callee-saved)
;;;;   x29      : saved stack-data SAP (set in `enter`, used in `leave`)
;;;;   x9       : scratch
;;;;
;;;; Calling convention from Lisp:
;;;;   x0 = stack-data SAP (8 uint32s)
;;;;   x1 = bytecode SAP   (uint32 little-endian opcodes/operands)
;;;;   x2 = primop-base SAP
;;;;   We jump to (primop-base + enter-offset).

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

(defparameter *primitive-code-offset* 4096)   ; one rotation page = 4 KiB
                                                ; (must be multiple of 4096 so
                                                ;  ARM64 add-imm with LSL #12
                                                ;  can express the offset)

(defstruct code-page
  (alloc 0)
  (code  (make-array *primitive-code-offset* :element-type '(unsigned-byte 8))))

(defun assemble-bytes (emitter)
  (let* ((section (sb-assem::make-section))
         (segment (sb-assem:make-segment)))
    (let ((sb-assem::*current-destination* section))
      (funcall emitter))
    (sb-assem::%assemble segment section)
    (sb-assem:segment-buffer segment)))

(defun emit-next (&optional (operand-bytes 0))
  ;; Load next opcode at [vIP + operand-bytes]; advance vIP by 4 + operand-bytes.
  (sb-assem:inst ldr *scratch-w* (sb-vm::@ *vip* operand-bytes))
  (sb-assem:inst add *vip* *vip* (+ 4 operand-bytes))
  (sb-assem:inst add *scratch* *primop-base* *scratch*)
  (let ((rotation (mod *stack-pointer* *stack-size*)))
    (unless (zerop rotation)
      (sb-assem:inst add *scratch* *scratch*
                     (* rotation *primitive-code-offset*))))
  (sb-assem:inst br *scratch*))

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

;;;; --- primops ---

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

;;;; control flow

;; Each control-flow primop computes the new vIP itself and then calls
;; emit-next without an operand-byte advance.
(defun jmp ()
  ;; Read 4-byte signed offset at [vIP]; vIP <- vIP + 4 + offset.
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

;; call: push vIP-after-operand on the C return stack (paired with xzr for
;; 16-byte alignment), then jump to the call target.
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

;;;; literals / inc / dec

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

;;;; djn / djn2 / ubench

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
  ;; Same as djn but with branch over the two NEXT sequences.
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

;; Inline asm benchmark: subtract one until zero, no NEXT.
(defun ubench ()
  (sb-assem:assemble (sb-assem::*current-destination*)
    head
    (sb-assem:inst subs (w@ 0) (w@ 0) 1)
    (sb-assem:inst b :ne head)
    (emit-next)))

;;;; enter / leave

;; enter assumes:
;;   x0 = stack-data SAP, x1 = bytecode SAP, x2 = primop-base SAP.
;; It saves callee-saved regs, loads the stack, sets x27/x28/x29, then NEXT.
(defun enter ()
  ;; All 8 rotations are emitted as collateral; only the sp=0 variant is
  ;; ever actually invoked from outside.
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
  ;; Store eight u32s back to the data SAP.
  (loop for i below *stack-size* do
        (sb-assem:inst str (w@ i) (sb-vm::@ *data-sap* (* 4 i))))
  ;; Pop callee-saved regs in reverse order.
  (sb-assem:inst ldp (x-reg 29) (x-reg 30) (sb-vm::@ (x-reg 31) 16 :post-index))
  (sb-assem:inst ldp (x-reg 27) (x-reg 28) (sb-vm::@ (x-reg 31) 16 :post-index))
  (sb-assem:inst ldp (x-reg 25) (x-reg 26) (sb-vm::@ (x-reg 31) 16 :post-index))
  (sb-assem:inst ldp (x-reg 23) (x-reg 24) (sb-vm::@ (x-reg 31) 16 :post-index))
  (sb-assem:inst ldp (x-reg 21) (x-reg 22) (sb-vm::@ (x-reg 31) 16 :post-index))
  (sb-assem:inst ldp (x-reg 19) (x-reg 20) (sb-vm::@ (x-reg 31) 16 :post-index))
  (sb-assem:inst ret))

;;;; --- Build code page ---

(defparameter *primops*
  '(enter leave-op lit
    swap dup drop
    add-op sub-op inc-op dec-op
    jmp jnz jz djn djn2
    call-op ret-op
    ubench))

(defparameter *primops-offsets* nil)
(defparameter *code-sap* nil)

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
(format t "~&Offsets: ~A~%" *primops-offsets*)

;;;; --- Symbolic assembler for bytecode ---

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

;;;; --- VM driver: alien-funcall into enter ---
;;;; A code SAP that begins at the `enter` offset, called with three SAP
;;;; arguments and returning void.
;;;;
;;;; We construct a transient SAP pointing to (code-base + enter-offset).

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
                                       sb-sys:system-area-pointer))
         stack-sap bytecode-sap code-base)))
    stack))

;;;; --- Smoke tests ---

;; (3 2 10) -> push 10 on top.  add of (3 2) = 5, sub (10 5) = 5.  Note the
;; AMD64 article's `vm` initialises the stack with the explicit list, putting
;; the *first* element at slot 0 (TOS at sp=0).  We do the same.
;;
;; AMD64 result was #(5 0 0 0 0 0 3 5).  The breakdown: stack[0]=5 (final
;; TOS), stack[6]=3 (preserved arg below the add), stack[7]=5 (the result of
;; sub overwriting the original TOS slot 7?).  Easiest check: TOS is 5.

(format t "~&add+sub: ~A~%" (vm '(3 2 10) '(add-op sub-op leave-op)))
(format t "~&dec loop: ~A~%" (vm '(1000000) '(dec-op 1 jnz -16 leave-op)))
(format t "~&djn loop: ~A~%" (vm '(1000000) '(djn -8 leave-op)))

(format t "~&Benchmarks (100M iterations each):~%")
(format t "~&  lit/sub/jnz~%")
(time (vm '(100000000) '(lit 1 sub-op jnz -20 leave-op)))
(format t "~&  dec/jnz~%")
(time (vm '(100000000) '(dec-op 1 jnz -16 leave-op)))
(format t "~&  djn~%")
(time (vm '(100000000) '(djn -8 leave-op)))
(format t "~&  djn2~%")
(time (vm '(100000000) '(djn2 -8 leave-op)))
(format t "~&  ubench (native)~%")
(time (vm '(100000000) '(ubench leave-op)))
