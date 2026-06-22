# Shell Style

Formatting is `shfmt`'s job (`-i 2 -ci -bn`: 2-space indent, indent case bodies, binary operators at line start) and
correctness is `shellcheck`'s. Both run at edit time via the auto-format hook and again in the pre-commit and pre-push
checks. This guide covers only the human conventions neither tool enforces. Open it when writing or reviewing a shell
script.

## Functions

- **Name `lowercase_with_underscores`**, with `()` after the name and no `function` keyword: `cleanup() { ... }`, not
  `function cleanup`.
- **Library functions carry a package prefix** in the `pkg::fn` form (`logging::info`, `http::get`) so a sourced
  helper's origin is visible at the call site.
- **Order functions below the constants and above `main`.** The last line of an executable script is `main "$@"`;
  nothing runs after it.

## Constants and environment

- **Constants and exported environment variables are `ALL_CAPS`.** Declare them at the top of the file, below the header
  comment and above the first function.
- **Mark them `readonly` once assigned**, and `export` the ones a child process needs. A value that is both is
  `readonly` and `export`ed.
- **Local variables stay `lowercase`** and are declared `local` inside their function.

## Documentation

- **Every script opens with a header comment**: one line on what the script does, then any usage or argument notes a
  reader needs before running it.
- **Each function carries a doc block** above its definition covering the parts that apply: a one-line description, the
  `Globals` it reads or writes, its positional `Args`, what it writes to `Outputs` (STDOUT), and its `Returns` (exit
  status). Omit a heading when the function has none of that kind.
- **Deferred work uses the `TODO(user)` form**: the owner's handle in parentheses, then the action, as in `TODO(brett):
  drop the fallback once the API ships v2`.

## Errors

- **Diagnostics and error messages go to STDERR**, never STDOUT: `echo "config not found" >&2`. STDOUT carries the
  script's data so a caller can pipe or capture it without errors leaking into the result.
