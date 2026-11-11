# 04 Late fees

## What to build

Overdue invoices get a late fee: 2% of the invoice amount for every full week it is late, never more than the invoice amount itself. Fees are whole pence, rounded down.

`python3 cli.py late-fee <number> <days-late>` prints the fee in pence for that invoice, for example `python3 cli.py late-fee INV-001 14` prints `50`. An unknown invoice number prints an error to standard error and exits 1.

The reminder emails (a later ticket) will call the same calculation from their own code and need a function they can import, with a stable signature they can depend on. Nothing else in the repo owns this yet.

## Acceptance criteria

- [ ] `python3 cli.py late-fee INV-001 14` prints `50`; `late-fee INV-002 6` prints `0`; `late-fee INV-002 700` prints `99000`.
- [ ] An unknown invoice number exits 1 with a message on standard error.
- [ ] The fee calculation can be imported and called without going through the command line.
- [ ] `python3 cli.py list` behaves as before.
- [ ] The suite passes with `python3 -m unittest`.
