(format t "~&Before: gap=~D~%" (- sb-vm:static-code-space-end
                                  (sb-sys:sap-int sb-vm:*static-code-space-free-pointer*)))
(loop for n in '(8192 16384 32768 65536) do
      (handler-case
          (let* ((bytes (make-array n :element-type '(unsigned-byte 8) :initial-element 0))
                 (gap-before (- sb-vm:static-code-space-end
                                (sb-sys:sap-int sb-vm:*static-code-space-free-pointer*))))
            (sb-vm::make-static-code-vector n bytes)
            (let ((gap-after (- sb-vm:static-code-space-end
                                (sb-sys:sap-int sb-vm:*static-code-space-free-pointer*))))
              (format t "~&Allocated ~D, used ~D bytes (gap ~D -> ~D)~%"
                      n (- gap-before gap-after) gap-before gap-after)))
        (error (c) (format t "~&Failed at ~D: ~A~%" n c)))
      (sb-ext:gc :full t))
