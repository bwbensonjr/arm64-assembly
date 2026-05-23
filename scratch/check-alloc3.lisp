(format t "~&Before: gap=~D~%" (- sb-vm:static-code-space-end
                                  (sb-sys:sap-int sb-vm:*static-code-space-free-pointer*)))
(let* ((n 16384)
       (bytes (make-array n :element-type '(unsigned-byte 8) :initial-element 0)))
  (sb-vm::make-static-code-vector n bytes)
  (format t "~&After 16k: gap=~D~%"
          (- sb-vm:static-code-space-end
             (sb-sys:sap-int sb-vm:*static-code-space-free-pointer*))))
