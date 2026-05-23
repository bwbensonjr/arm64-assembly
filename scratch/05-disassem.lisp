;;;; Capture disassembly snippets for the article.
(load "scratch/04-vm-ffi.lisp")

(defun show-disasm (label offset length)
  (let ((sap (sb-sys:sap+ *code-sap* offset)))
    (format t "~&==== ~A (offset ~D, ~D bytes) ====~%" label offset length)
    (sb-disassem:disassemble-memory sap length)
    (terpri)))

;; A few representative primops at sp=0
(show-disasm 'enter   0  88)
(show-disasm 'leave-op 88 60)
(show-disasm 'lit     148 24)
(show-disasm 'swap    172 32)
(show-disasm 'add-op  248 24)
(show-disasm 'jmp     352 32)
(show-disasm 'jnz     384 36)
(show-disasm 'djn     456 40)
(show-disasm 'djn2    496 64)
(show-disasm 'call-op 560 36)
(show-disasm 'ret-op  596 24)
(show-disasm 'ubench  620 24)

;; And the same ADD-OP at sp=1 to show the rotation offset
(show-disasm 'add-op-sp1 (+ 248 (* 1 4096)) 24)
