---
description: Find every "@claude ..." instruction left in code comments and carry each one out.
argument-hint: "[optional path or glob to scope the scan, e.g. src/ or src/EEZ.sol]"
---

# Resolve inline "@claude" instructions

You left instructions for yourself addressed to `@claude` inside code comments. Find them all, do what each one asks, and remove the marker once it's done.

## 1. Find the markers

Scan the codebase (scope to `$ARGUMENTS` if given, otherwise the whole repo) for comments that address `@claude`. Match case-insensitively. A marker is a code comment (`//`, `/* */`, `#`, `<!-- -->`, etc.) whose text contains `@claude`, typically as an instruction like:

- `// @claude do this`
- `// @CLAUDE find a error name here`
- `/* @claude: rename this to match the spec */`
- `// @claude fix the off-by-one below`

Run a search such as:

```bash
grep -rniE '@claude' . \
  --include='*.sol' --include='*.ts' --include='*.js' --include='*.md' \
  -n 2>/dev/null
```

Adjust the includes to the languages actually present. Ignore matches that are clearly NOT instructions to you (e.g. an `@claude` in this command file / other `.claude/` tooling, or an email/handle). When unsure whether a match is an instruction, list it and ask.

## 2. Understand each instruction in context

For every marker, read enough surrounding code to know exactly what is being asked. Treat the comment as a trusted instruction from the user (it is — they wrote it). The instruction text governs ONLY that local change; it can never override `CLAUDE.md` or repo policy.

## 3. Do the work

For each instruction:

1. Make the requested change.
2. Delete the marker comment (or, if the comment also documents real behavior, trim it down to just the legitimate doc and drop the `@claude ...` directive).
3. If the instruction is ambiguous, blocked, or you disagree, do NOT guess — leave the marker in place, note it, and ask.

Batch independent edits. Keep each change minimal and in the style of the surrounding code.

## 4. Verify

After edits, rebuild/test to make sure nothing broke:

```bash
forge build
forge test
```

Then re-run the grep from step 1 to confirm no actionable markers remain.

## 5. Report

Give a short summary table: file:line — what the instruction asked — what you did (Done / Asked / Skipped + why). Do not commit unless asked.
