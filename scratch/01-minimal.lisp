;;;; Smoke test for the minimal example in doc/ARM64-ASSEMBLY.md.

(let* ((segment (sb-assem:make-segment))
       (x0 (sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::any-reg) 0)))
  (sb-assem:assemble (segment nil)
    (sb-assem:inst mov x0 42)
    (sb-assem:inst ret))
  (sb-assem:finalize-segment segment)
  (let* ((bytes (sb-assem:segment-buffer segment)))
    (format t "~&Bytes: ~A~%" (coerce bytes 'list))
    (let* ((code (sb-vm::make-static-code-vector (length bytes) bytes))
           (sap (sb-sys:vector-sap code)))
      (sb-alien:alien-funcall
       (sb-alien:extern-alien "os_flush_icache"
                              (function sb-alien:void
                                        sb-sys:system-area-pointer
                                        sb-alien:unsigned-long))
       sap (length bytes))
      (let ((result (sb-alien:alien-funcall
                     (sb-alien:sap-alien sap (function sb-alien:int)))))
        (format t "Result: ~D~%" result)
        result))))
