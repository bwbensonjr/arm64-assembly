(require :sb-posix)

;; What if we write to MAP_JIT page WITHOUT calling pthread_jit_write_protect_np?
(handler-case
    (let* ((sap (sb-posix:mmap nil 4096
                               (logior sb-posix:prot-read sb-posix:prot-write sb-posix:prot-exec)
                               (logior sb-posix:map-anon sb-posix:map-private #x800)
                               -1 0)))
      (format t "~&mmap returned: ~A~%" sap)
      (setf (sb-sys:sap-ref-8 sap 0) #x40)
      (format t "~&Wrote one byte without jit-wp.~%"))
  (error (c) (format t "~&Failed: ~A~%" c)))
