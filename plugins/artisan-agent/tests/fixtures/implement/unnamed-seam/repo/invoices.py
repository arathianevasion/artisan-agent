"""The invoice store. Amounts are integer pence."""

INVOICES = [
    {"number": "INV-001", "customer": "Ada", "amount_pence": 1250},
    {"number": "INV-002", "customer": "Grace", "amount_pence": 99000},
]


def all_invoices():
    return list(INVOICES)
