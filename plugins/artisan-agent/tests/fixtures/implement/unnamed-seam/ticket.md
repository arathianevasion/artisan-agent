# 02 Export invoices as CSV

## What to build

The bookkeeper wants invoices in a spreadsheet. `python3 cli.py export` writes every invoice to standard output as CSV: a header row `number,customer,amount_pence`, then one row per invoice in store order.

The monthly email report (a later ticket) will attach the same CSV, so producing the CSV must not depend on the command line or on standard output.

## Acceptance criteria

- [ ] `python3 cli.py export` prints the header row, then one row per invoice.
- [ ] The CSV can be produced without going through the command line.
- [ ] `python3 cli.py list` behaves as before.
- [ ] The suite passes with `python3 -m unittest`.
