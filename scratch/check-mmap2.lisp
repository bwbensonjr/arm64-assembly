(require :sb-posix)

;; Try mmap with PROT_READ|PROT_WRITE|PROT_EXEC and MAP_PRIVATE|MAP_ANON.
;; On Apple Silicon this typically fails unless MAP_JIT (#x800) is set.
(handler-case
    (let ((sap (sb-posix:mmap nil 4096
                              (logior sb-posix:prot-read sb-posix:prot-write sb-posix:prot-exec)
                              (logior sb-posix:map-anon sb-posix:map-private)
                              -1 0)))
      (format t "~&Plain mmap RWX: success ~A~%" sap))
  (error (c) (format t "~&Plain mmap RWX failed: ~A~%" c)))

;; Try with MAP_JIT (#x800).
(handler-case
    (let ((sap (sb-posix:mmap nil 4096
                              (logior sb-posix:prot-read sb-posix:prot-write sb-posix:prot-exec)
                              (logior sb-posix:map-anon sb-posix:map-private #x800)
                              -1 0)))
      (format t "~&MAP_JIT mmap RWX: success ~A~%" sap))
  (error (c) (format t "~&MAP_JIT mmap RWX failed: ~A~%" c)))
