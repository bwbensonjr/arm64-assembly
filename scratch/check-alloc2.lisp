(format t "~&Before: gap=~D~%" (- sb-vm:static-code-space-end
                                  (sb-sys:sap-int sb-vm:*static-code-space-free-pointer*)))
(loop for n in '(1024 2048 4096 8192 16384 32768) do
      (handler-case
          (let ((bytes (make-array n :element-type '(unsigned-byte 8) :initial-element 0)))
            (sb-vm::make-static-code-vector n bytes)
            (format t "~&Allocated ~D, gap=~D~%" n
                    (- sb-vm:static-code-space-end
                       (sb-sys:sap-int sb-vm:*static-code-space-free-pointer*))))
        (error (c) (format t "~&Failed at ~D: ~A~%" n c))))
