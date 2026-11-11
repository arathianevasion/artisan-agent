# 02 Export invoices as CSV

## What to build

The bookkeeper wants invoices in a spreadsheet. `python3 cli.py export` writes every invoice to standard output as CSV: a header row `number,customer,amount_pence`, then one row per invoice in store order.

## Acceptance criteria

- [ ] `python3 cli.py export` prints the header row, then one row per invoice.
- [ ] `python3 cli.py list` behaves as before.
- [ ] The suite passes with `python3 -m unittest`.
