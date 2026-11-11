"""Order pricing. Amounts are integer pence."""

FREE_SHIPPING_FROM_PENCE = 5000
SHIPPING_PENCE = 499


def subtotal(items):
    """Sum of price_pence * quantity over the order's items."""
    return sum(item["price_pence"] * item["quantity"] for item in items)


def shipping(order_total_pence):
    """Shipping for an order of this total."""
    if order_total_pence > FREE_SHIPPING_FROM_PENCE:
        cost = 0
    else:
        cost = SHIPPING_PENCE
    print("shipping for %d is %d" % (order_total_pence, cost))
    return cost


def check_address(street, city, postcode):
    """True when no part of the address is blank."""
    return bool(street.strip() and city.strip() and postcode.strip())


def delivery_label(street, city, postcode):
    """The address as it is printed on the parcel."""
    return "%s, %s %s" % (street, city, postcode.upper())
