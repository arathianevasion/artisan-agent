# 01 Slugify note titles

## What to build

Notes need URL slugs. Add `slugify(title)` to `text.py`: it lowercases the title, turns every run of characters that aren't letters or digits into a single hyphen, and leaves no hyphen at either end.

## Seams

- `text.slugify(title)`, tested in `tests/test_text.py`.

## Acceptance criteria

- [ ] `slugify("Hello, World!")` returns `"hello-world"`.
- [ ] `slugify("  --Weekly   Plan 2--  ")` returns `"weekly-plan-2"`.
- [ ] The suite passes with `python3 -m unittest`.
