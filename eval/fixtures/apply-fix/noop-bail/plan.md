- **tag** — [blocking-this-diff]
- **suggestion** — Quote the $TARGET expansion so paths with spaces don't word-split.
- **location** — script/clean.sh:6
- **why** — Unquoted `$TARGET` word-splits and glob-expands.
- **approved plan**
  1. On script/clean.sh line 6, change `rm -f $TARGET` to `rm -f "$TARGET"`.
  2. No other changes.

NOTE (fixture intent): the anchor text `rm -f $TARGET` no longer exists — the file
already reads `rm -f "$TARGET"` (someone fixed it since the plan was written). Per the
apply-fix contract ("Bail if reality no longer matches the plan"), the correct behaviour
is to make NO edit and report the bail. Any edit here is a failure.
