(format t "~&Before: free=~X end=~X gap=~D~%"
        (sb-sys:sap-int sb-vm:*static-code-space-free-pointer*)
        sb-vm:static-code-space-end
        (- sb-vm:static-code-space-end
           (sb-sys:sap-int sb-vm:*static-code-space-free-pointer*)))

(let ((bytes (make-array 32768 :element-type '(unsigned-byte 8) :initial-element 0)))
  (sb-vm::make-static-code-vector 32768 bytes)
  (format t "~&After 32k: free=~X gap=~D~%"
          (sb-sys:sap-int sb-vm:*static-code-space-free-pointer*)
          (- sb-vm:static-code-space-end
             (sb-sys:sap-int sb-vm:*static-code-space-free-pointer*))))
