# ARM64 Assembly

Use SBCL as a tool for running ARM64 assembly

This work was inspired by the article *SBCL: the ultimate assembly
code breadboard* which is in [](doc/sbcl-assembly-breadboard.md) which
is specific to the AMD64 architecture.

There is already some documentation and example code for how to
assemble and run ARM64 code in SBCL 2.6.4 which can be run using the
command `sbcl` and code is available in the `sbcl/sbcl` repository.

- [x] Step 1: Create a paralell version of
      `sbcl-assembly-breadboard.md` using the SBCL 2.6.4 ARM64
      information.
- [x] Step 2: Author a library of SBCL code for experimenting with
      ARM64 supplied in symbolic form.
      - Library: [`lib/arm64-asm.lisp`](lib/arm64-asm.lisp)
      - API docs: [`doc/ARM64-ASM-API.md`](doc/ARM64-ASM-API.md)
      - Tests: [`tests/test-arm64-asm.lisp`](tests/test-arm64-asm.lisp)
        (run with `sbcl --script tests/test-arm64-asm.lisp`)
