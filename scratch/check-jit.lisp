(require :sb-posix)

(defun mmap-jit (size)
  (sb-posix:mmap nil size
                 (logior sb-posix:prot-read sb-posix:prot-write sb-posix:prot-exec)
                 (logior sb-posix:map-anon sb-posix:map-private #x800)
                 -1 0))

(defun jit-wp (writable)
  (sb-alien:alien-funcall
   (sb-alien:extern-alien "pthread_jit_write_protect_np"
                          (function sb-alien:void sb-alien:int))
   (if writable 0 1)))

(defun flush-icache (sap n)
  (sb-alien:alien-funcall
   (sb-alien:extern-alien "os_flush_icache"
                          (function sb-alien:void
                                    sb-sys:system-area-pointer
                                    sb-alien:unsigned-long))
   sap n))

;; Build small program: mov w0, #99; ret.  Bytes: e3 0c 80 52 c0 03 5f d6
;; (We computed mov w0,#42 = 64 5 128 210; that was x0.  For w0 form we need
;; mov w-zero-extended-32-bit which assembles differently.  Easier: reuse
;; the article's bytes for "mov x0, 42 ; ret".)
(let* ((bytes #(64 5 128 210 192 3 95 214))
       (sap (mmap-jit 4096)))
  (jit-wp t)                      ; W mode
  ;; Copy bytes into the page.
  (loop for i below (length bytes)
        do (setf (sb-sys:sap-ref-8 sap i) (aref bytes i)))
  (jit-wp nil)                    ; X mode
  (flush-icache sap (length bytes))
  (let ((result (sb-alien:alien-funcall
                 (sb-alien:sap-alien sap (function sb-alien:int)))))
    (format t "~&mmap-JIT result: ~A~%" result)))
