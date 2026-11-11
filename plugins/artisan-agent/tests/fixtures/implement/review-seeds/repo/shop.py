"""Order pricing. Amounts are integer pence."""


def subtotal(items):
    """Sum of price_pence * quantity over the order's items."""
    return sum(item["price_pence"] * item["quantity"] for item in items)
