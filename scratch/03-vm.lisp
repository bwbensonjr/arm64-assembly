;;;; Phase B: rotating-stack VM, ARM64 port.
;;;;
;;;; Stack slots:   x19..x26 (callee-saved on AAPCS64; w-views w19..w26)
;;;; Primop base:   x27 (callee-saved)
;;;; Virtual IP:    x28 (callee-saved)
;;;; Return stack:  x29 (we use it as a separate VM return-stack pointer
;;;;                       so as not to mess with the C SP / 16-byte align)
;;;; Scratch:       x9  (callee-clobbered, free to use)

(defun x-reg (n) (sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::any-reg)     n))
(defun w-reg (n) (sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::32-bit-reg) n))

(defparameter *stack-base* 19)
(defparameter *stack-size* 8)
(defparameter *stack-pointer* 0)
(defun w@ (i)                              ; w-view of stack slot relative to *sp*
  (w-reg (+ *stack-base* (mod (+ i *stack-pointer*) *stack-size*))))
(defun x@ (i)                              ; x-view
  (x-reg (+ *stack-base* (mod (+ i *stack-pointer*) *stack-size*))))

(defparameter *primop-base* (x-reg 27))
(defparameter *vip*         (x-reg 28))
(defparameter *vip-w*       (w-reg 28))
(defparameter *vrsp*        (x-reg 29))
(defparameter *scratch*     (x-reg 9))
(defparameter *scratch-w*   (w-reg 9))

(defparameter *primitive-code-offset* (* 4 1024))   ; one 4 KiB page per stack rotation

(defstruct code-page
  (alloc 0)
  (code  (make-array *primitive-code-offset* :element-type '(unsigned-byte 8))))

;;; Assemble into a section, drain into a segment, return bytes vector.
(defun assemble-bytes (emitter)
  (let* ((section (sb-assem::make-section))
         (segment (sb-assem:make-segment)))
    (let ((sb-assem::*current-destination* section))
      (funcall emitter))
    (sb-assem::%assemble segment section)
    (sb-assem:segment-buffer segment)))

;;; NEXT
;;;   ldr   w9,  [x28]               ; load next 4-byte offset
;;;   add   x28, x28, #(4 + extra)   ; advance vIP
;;;   add   x9,  x27, x9             ; base + offset
;;;   br    x9
;;; If rotation>0, add (rotation * page-offset) before the branch using a
;;; second add (we use ldr+add+add+br rather than x86's lea trick).
(defun emit-next (&optional (extra 0))
  (sb-assem:inst ldr *scratch-w* (sb-vm::@ *vip*))
  (let ((advance (+ 4 extra)))
    (when (not (zerop advance))
      (sb-assem:inst add *vip* *vip* advance)))
  (sb-assem:inst add *scratch* *primop-base* *scratch*)
  (let ((rotation (mod *stack-pointer* *stack-size*)))
    (unless (zerop rotation)
      (sb-assem:inst add *scratch* *scratch*
                     (* rotation *primitive-code-offset*))))
  (sb-assem:inst br *scratch*))

;;; pad-to-alignment in 4-byte nops
(defun emit-nops-to (segment current-bytes target-bytes)
  (declare (ignore segment))
  (loop while (< current-bytes target-bytes) do
        (sb-assem:inst nop)
        (incf current-bytes 4))
  current-bytes)

;;; emit-code: emit one variant per stack rotation, padded so each variant
;;; starts at the same offset within its code-page.
(defun emit-code (pages emitter)
  (assert (= *stack-size* (length pages)))
  ;; All variants must start at the same offset.  Find the rightmost
  ;; current alloc, round up to 4 (instructions are 4 bytes).
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
            (assert (<= (+ (code-page-alloc page) (length bytes))
                        (length (code-page-code page))))
            (setf (code-page-alloc page)
                  (+ (code-page-alloc page) (length bytes)))))
    alloc-start))

(defun emit-all-code (&rest emitters)
  (let ((pages (loop repeat *stack-size*
                     for page = (make-code-page)
                     do (fill (code-page-code page) #x1F)  ; junk
                     collect page)))
    (values (mapcar (lambda (e) (emit-code pages e)) emitters)
            pages)))

;;; --- Primops ---

(defun swap ()
  ;; (xchg @0 @1)  ->  three-instruction temp-swap on ARM64
  (sb-assem:inst mov *scratch-w* (w@ 0))
  (sb-assem:inst mov (w@ 0) (w@ 1))
  (sb-assem:inst mov (w@ 1) *scratch-w*)
  (emit-next))

(defun dup ()
  (decf *stack-pointer*)              ; grow stack
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

;; Quick smoke: emit swap/dup/drop/add/sub and disassemble the first variant.
(multiple-value-bind (offsets pages) (emit-all-code 'swap 'dup 'drop 'add-op 'sub-op)
  (format t "~&Offsets: ~A~%" offsets)
  (format t "~&Page0 alloc: ~A~%" (code-page-alloc (first pages)))
  (let* ((bytes (subseq (code-page-code (first pages))
                        0 (code-page-alloc (first pages))))
         (vec   (make-array (length bytes) :element-type '(unsigned-byte 8)
                                            :initial-contents bytes)))
    (sb-sys:with-pinned-objects (vec)
      (format t "~&-- Page0 disassembly --~%")
      (sb-disassem:disassemble-memory (sb-sys:vector-sap vec) (length vec))))
  (let* ((bytes (subseq (code-page-code (second pages))
                        0 (code-page-alloc (second pages))))
         (vec   (make-array (length bytes) :element-type '(unsigned-byte 8)
                                            :initial-contents bytes)))
    (sb-sys:with-pinned-objects (vec)
      (format t "~&-- Page1 disassembly (sp=1, swap section) --~%")
      (sb-disassem:disassemble-memory (sb-sys:vector-sap vec) 32))))
