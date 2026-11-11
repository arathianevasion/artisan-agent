# 03 Shipping and delivery labels

## What to build

Customers pay shipping on small orders only. `shipping(order_total_pence)` in `shop.py` returns 0 for orders of £50 (5000 pence) or more, and 499 pence below that. Parcels need a label: `delivery_label(street, city, postcode)` returns `"street, city POSTCODE"` with the postcode upper-cased, and `check_address(street, city, postcode)` rejects an address with any blank part.

This is a second attempt. The first attempt's worker committed its work on this branch and was stopped before its review; build on that commit rather than starting again.

## Seams

- `shop.shipping`, `shop.delivery_label` and `shop.check_address`, tested in `tests/test_shop.py`.

## Acceptance criteria

- [ ] An order of 5000 pence or more ships free.
- [ ] An order under 5000 pence pays 499 pence shipping.
- [ ] `delivery_label("1 High St", "Leeds", "ls1 4ap")` returns `"1 High St, Leeds LS1 4AP"`.
- [ ] `check_address` rejects an address with a blank part.
- [ ] The suite passes with `python3 -m unittest`.
