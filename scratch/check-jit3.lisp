(require :sb-posix)

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

(let* ((bytes (make-array 8 :element-type '(unsigned-byte 8)
                            :initial-contents #(64 5 128 210 192 3 95 214)))
       (sap (mmap-jit 4096)))
  (jit-memcpy sap bytes)
  (flush-icache sap (length bytes))
  (let ((result (sb-alien:alien-funcall
                 (sb-alien:sap-alien sap (function sb-alien:int)))))
    (format t "~&jit_memcpy + mmap result: ~A~%" result)))

(let* ((size (* 8 4096))
       (sap (mmap-jit size))
       (bytes (make-array 8 :element-type '(unsigned-byte 8)
                            :initial-contents #(64 5 128 210 192 3 95 214))))
  (jit-memcpy sap bytes)
  (flush-icache sap (length bytes))
  (format t "~&Big mmap+memcpy: result=~A~%"
          (sb-alien:alien-funcall
           (sb-alien:sap-alien sap (function sb-alien:int)))))
