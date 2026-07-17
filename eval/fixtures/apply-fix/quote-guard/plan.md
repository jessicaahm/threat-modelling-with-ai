- **tag** — [blocking-this-diff]
- **suggestion** — Quote the $TARGET expansion so paths with spaces don't word-split and globs can't inject.
- **location** — script/clean.sh:6
- **why** — Unquoted `$TARGET` in `rm -f $TARGET` word-splits on spaces and expands globs, so a crafted argument can delete unintended files.
- **approved plan**
  1. On script/clean.sh line 6, change `rm -f $TARGET` to `rm -f "$TARGET"`.
  2. No other changes.
