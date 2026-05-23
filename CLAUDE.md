# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo is a **documentation/exploration project**, not a buildable codebase. The goal is to use SBCL (Steel Bank Common Lisp) 2.6.4 as an interactive assembler/runtime for ARM64 machine code, mirroring the technique that Paul Khuong's blog post "SBCL: the ultimate assembly code breadboard" demonstrates for AMD64.

The current task (per `README.md`) is **Step 1**: produce an ARM64 counterpart of `doc/sbcl-assembly-breadboard.md` (AMD64) using the conventions and APIs documented in `doc/ARM64-ASSEMBLY.md`.

## Repository layout

- `README.md` — project goal and task checklist.
- `doc/sbcl-assembly-breadboard.md` — the AMD64 reference article being ported. Treat as **source material**, not as code to modify.
- `doc/ARM64-ASSEMBLY.md` — the ARM64-specific notes (TN creation, ABI register conventions, `make-static-code-vector`, `os_flush_icache`). This is the in-progress target document and the authoritative ARM64 API guide for this project.

## Working environment

- A second working directory is registered: `/Users/bwb/src/github.com/sbcl/sbcl` (the upstream SBCL source). Read it for ground truth on SBCL internals — **do not modify it**.
- ARM64 instruction definitions live in `../../sbcl/sbcl/src/compiler/arm64/insts.lisp`. This is the canonical reference for accepted instruction names and operand shapes when writing ARM64 `(sb-assem:inst ...)` forms. The AMD64 equivalent (used by the breadboard article) is in `src/compiler/x86-64/insts.lisp`.
- Run SBCL with `sbcl` from the shell. There is no build step in this repo.

## Key API differences vs. the AMD64 article

When porting AMD64 examples to ARM64, the following substitutions apply (see `doc/ARM64-ASSEMBLY.md` for details):

- **TN creation**: AMD64 examples use named TNs like `sb-vm::r8d-tn`. On ARM64, the article deliberately uses `(sb-c:make-random-tn (sb-c:sc-or-lose 'sb-vm::any-reg) N)` for ABI register N, because `sb-vm::r0-tn` is **not** the ABI's `x0`. Do not assume name-based TN access works the same way across backends.
- **Effective addresses**: AMD64 uses `(sb-vm::make-ea :dword :base ... :disp ...)`. ARM64 uses `(sb-vm::@ base disp)`.
- **Code installation**: ARM64 uses `sb-vm::make-static-code-vector` plus an explicit call to the `os_flush_icache` alien — the icache flush is mandatory on ARM64 and must not be omitted, unlike on AMD64 where the AMD64 article does not need it.
- **Calling convention**: snippets are invoked through the foreign-call ABI (`sb-alien:sap-alien` + `alien-funcall`), so arguments/results follow the platform C ABI (`x0`, `x1`, …), not SBCL's internal Lisp register conventions.

## Style for documentation work

- The ARM64 article (`doc/ARM64-ASSEMBLY.md`) is written in prose + Lisp code blocks. Match that style when extending it.
- Use ASCII double quotes in any code samples (per global instructions).
- Don't present internal SBCL APIs as stable; the existing article calls them out as version-sensitive, and that framing should be preserved.
