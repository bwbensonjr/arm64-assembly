;;;; tests/test-arm64-asm.lisp -- exercises lib/arm64-asm.lisp
;;;;
;;;; Run with:
;;;;   sbcl --script tests/test-arm64-asm.lisp
;;;; Exits non-zero if any test fails.

(load "lib/arm64-asm.lisp")

(defpackage #:arm64-asm-tests
  (:use #:cl)
  (:local-nicknames (#:a #:arm64-asm)))

(in-package #:arm64-asm-tests)

;;;; --- Tiny test harness --------------------------------------------------

(defparameter *fail-count* 0)
(defparameter *pass-count* 0)

(defun report (name ok actual expected)
  (cond (ok
         (incf *pass-count*)
         (format t "  ok    ~A~%" name))
        (t
         (incf *fail-count*)
         (format t "  FAIL  ~A~%      actual:   ~S~%      expected: ~S~%"
                 name actual expected))))

(defmacro check-equal (name expected form)
  (let ((actual (gensym)) (expected-val (gensym)))
    `(let ((,actual ,form)
           (,expected-val ,expected))
       (report ,name (equalp ,actual ,expected-val) ,actual ,expected-val))))

(defmacro check-equalp-vector (name expected form)
  `(check-equal ,name ,expected ,form))

;;;; --- Tests --------------------------------------------------------------

;; 1. Register TN constructors return distinguishable TNs of the right SC.

(let ((x0 (a:x-tn 0))
      (x1 (a:x-tn 1))
      (w0 (a:w-tn 0)))
  (check-equal "x-tn distinguishes offsets"
               t
               (and (eql 0 (sb-c::tn-offset x0))
                    (eql 1 (sb-c::tn-offset x1))))
  (check-equal "w-tn returns 32-bit-reg SC"
               "32-BIT-REG"
               (symbol-name (sb-c::sc-name (sb-c::tn-sc w0))))
  (check-equal "x-tn returns any-reg SC"
               "ANY-REG"
               (symbol-name (sb-c::sc-name (sb-c::tn-sc x0)))))

;; 2. assemble-bytes produces the documented "MOV X0, 42 ; RET" encoding.

(check-equalp-vector
 "assemble-bytes(mov x0,42 ; ret) matches documented bytes"
 (coerce '(64 5 128 210 192 3 95 214) '(simple-array (unsigned-byte 8) (*)))
 (a:assemble-bytes
  (lambda ()
    (a:inst mov (a:x-tn 0) 42)
    (a:inst ret))))

;; 3. assemble-bytes is reusable: same emitter run twice yields equal bytes.

(let ((emitter (lambda ()
                 (a:inst mov (a:w-tn 0) 7)
                 (a:inst ret))))
  (check-equal "assemble-bytes is deterministic"
               t
               (equalp (a:assemble-bytes emitter)
                       (a:assemble-bytes emitter))))

;; 4. install-static-code returns a SAP and a vector matching the input.

(let* ((bytes (a:assemble-bytes
               (lambda ()
                 (a:inst mov (a:x-tn 0) 99)
                 (a:inst ret)))))
  (multiple-value-bind (sap code) (a:install-static-code bytes)
    (check-equal "install-static-code returns SAP"
                 t (sb-sys:system-area-pointer-p sap))
    (check-equal "install-static-code copies bytes verbatim"
                 t (equalp (coerce bytes 'list) (coerce code 'list)))))

;; 5. call-int-thunk runs the documented minimal example and returns 42.

(check-equal "call-int-thunk: mov x0,42 ; ret => 42"
             42
             (a:call-int-thunk
              (lambda ()
                (a:inst mov (a:x-tn 0) 42)
                (a:inst ret))))

;; 6. A different immediate to make sure the answer is not coincidence.

(check-equal "call-int-thunk: mov x0,1234 ; ret => 1234"
             1234
             (a:call-int-thunk
              (lambda ()
                (a:inst mov (a:x-tn 0) 1234)
                (a:inst ret))))

;; 7. Two-argument int-int->int thunk, verifying that w-tn 0 / w-tn 1
;; really are AAPCS64 W0/W1.

(let* ((bytes (a:assemble-bytes
               (lambda ()
                 (a:inst add (a:w-tn 0) (a:w-tn 0) (a:w-tn 1))
                 (a:inst ret)))))
  (multiple-value-bind (sap code) (a:install-static-code bytes)
    (declare (ignore code))
    (check-equal "ABI: add w0,w0,w1 returns x+y"
                 42
                 (sb-alien:alien-funcall
                  (sb-alien:sap-alien sap
                                      (function sb-alien:int
                                                sb-alien:int
                                                sb-alien:int))
                  17 25))))

;; 8. Section-based assembly: a labelled loop summing 1..100 = 5050.

(check-equal "assemble-section-bytes: labelled sum 1..100 => 5050"
             5050
             (a:call-int-thunk
              (lambda ()
                (let ((w0 (a:w-tn 0))
                      (w1 (a:w-tn 1)))
                  (a:inst mov w0 0)
                  (a:inst mov w1 100)
                  (a:assemble (sb-assem::*current-destination*)
                    loop
                    (a:inst add w0 w0 w1)
                    (a:inst subs w1 w1 1)
                    (a:inst b :ne loop))
                  (a:inst ret)))))

;; 9. assemble-section-bytes can also be used directly to collect bytes
;; (verify it returns an octet vector that is a multiple of 4 bytes,
;; since every ARM64 instruction is 4 bytes).

(let ((bytes (a:assemble-section-bytes
              (lambda ()
                (a:assemble (sb-assem::*current-destination*)
                  (a:inst cbz (a:w-tn 0) done)
                  (a:inst mov (a:w-tn 0) 1)
                  done
                  (a:inst ret))))))
  (check-equal "assemble-section-bytes returns octet vector"
               '(unsigned-byte 8)
               (array-element-type bytes))
  (check-equal "assemble-section-bytes length is 4-aligned"
               0
               (mod (length bytes) 4)))

;; 10. Memory operand: load via @ from a pointer passed in x0.

(let* ((bytes (a:assemble-bytes
               (lambda ()
                 (a:inst ldr (a:w-tn 0) (a:@ (a:x-tn 0)))
                 (a:inst ret))))
       (buf (make-array 1 :element-type '(unsigned-byte 32)
                          :initial-contents '(#xDEADBEEF))))
  (multiple-value-bind (sap code) (a:install-static-code bytes)
    (declare (ignore code))
    (sb-sys:with-pinned-objects (buf)
      (check-equal "@ as memory operand: ldr w0,[x0] reads buffer"
                   #xDEADBEEF
                   (ldb (byte 32 0)
                        (sb-alien:alien-funcall
                         (sb-alien:sap-alien sap
                                             (function sb-alien:unsigned-int
                                                       sb-sys:system-area-pointer))
                         (sb-sys:vector-sap buf)))))))

;; 11. flush-icache and install-static-code over a noop-only thunk should
;; not crash and should return 0 from x0 if the snippet sets x0=0.

(check-equal "explicit zero return"
             0
             (a:call-int-thunk
              (lambda ()
                (a:inst mov (a:w-tn 0) 0)
                (a:inst ret))))

;;;; --- Summary ------------------------------------------------------------

(format t "~%~D passed, ~D failed.~%" *pass-count* *fail-count*)
(when (plusp *fail-count*)
  (sb-ext:exit :code 1))
(sb-ext:exit :code 0)
