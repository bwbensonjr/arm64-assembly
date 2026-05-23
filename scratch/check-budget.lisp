;; Determine the static code budget on this build.
(format t "~&free-pointer: ~X~%" (sb-sys:sap-int sb-vm:*static-code-space-free-pointer*))
(format t "~&end:          ~X~%" sb-vm:static-code-space-end)
(format t "~&start - end / 1024: ~A~%"
        (- sb-vm:static-code-space-end
           (sb-sys:sap-int sb-vm:*static-code-space-free-pointer*)))
