;;;; Phase A: confirm w-registers, ldr/str, br, and labels via the
;;;; section -> %assemble path that supports tagbody-style labels.

(defun x-reg (n) (sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::any-reg)     n))
(defun w-reg (n) (sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::32-bit-reg) n))

;;; Assemble into a SECTION (so labels work), then drain into a SEGMENT.
(defun assemble-bytes (emitter)
  (let* ((section (sb-assem::make-section))
         (segment (sb-assem:make-segment)))
    (let ((sb-assem::*current-destination* section))
      (funcall emitter))
    (sb-assem::%assemble segment section)
    (sb-assem:segment-buffer segment)))

(defun install-and-call-int (emitter)
  (let* ((bytes (assemble-bytes emitter))
         (code (sb-vm::make-static-code-vector (length bytes) bytes))
         (sap (sb-sys:vector-sap code)))
    (sb-alien:alien-funcall
     (sb-alien:extern-alien "os_flush_icache"
                            (function sb-alien:void
                                      sb-sys:system-area-pointer
                                      sb-alien:unsigned-long))
     sap (length bytes))
    (values
     (sb-alien:alien-funcall
      (sb-alien:sap-alien sap (function sb-alien:int)))
     bytes)))

;; A1: 32-bit immediate move + ret.
(format t "~&A1: ~A~%"
        (multiple-value-list
         (install-and-call-int
          (lambda ()
            (sb-assem:inst mov (w-reg 0) 1234)
            (sb-assem:inst ret)))))

;; A2: add of two w-regs.
(format t "~&A2: ~A~%"
        (multiple-value-list
         (install-and-call-int
          (lambda ()
            (sb-assem:inst mov (w-reg 1) 100)
            (sb-assem:inst mov (w-reg 2) 23)
            (sb-assem:inst add (w-reg 0) (w-reg 1) (w-reg 2))
            (sb-assem:inst ret)))))

;; A3: indirect branch via BR.
(format t "~&A3: ~A~%"
        (multiple-value-list
         (install-and-call-int
          (lambda ()
            (sb-assem:assemble (sb-assem::*current-destination*)
              (sb-assem:inst adr (x-reg 9) target)
              (sb-assem:inst br  (x-reg 9))
              (sb-assem:inst mov (w-reg 0) 999)
              (sb-assem:inst ret)
              target
              (sb-assem:inst mov (w-reg 0) 42)
              (sb-assem:inst ret))))))

;; A4: simple loop counting from 5 down to 0; return the count of iterations.
(format t "~&A4: ~A~%"
        (multiple-value-list
         (install-and-call-int
          (lambda ()
            (sb-assem:assemble (sb-assem::*current-destination*)
              ;; w0 = 0 ; w1 = 5
              (sb-assem:inst mov (w-reg 0) 0)
              (sb-assem:inst mov (w-reg 1) 5)
              loop
              (sb-assem:inst cbz (w-reg 1) done)
              (sb-assem:inst add (w-reg 0) (w-reg 0) 1)
              (sb-assem:inst sub (w-reg 1) (w-reg 1) 1)
              (sb-assem:inst b loop)
              done
              (sb-assem:inst ret))))))
