import unittest

from shop import check_address, delivery_label, shipping, subtotal


class SubtotalTest(unittest.TestCase):
    def test_sums_price_times_quantity(self):
        items = [{"price_pence": 250, "quantity": 2}, {"price_pence": 100, "quantity": 1}]
        self.assertEqual(subtotal(items), 600)


class ShippingTest(unittest.TestCase):
    def test_large_orders_ship_free(self):
        self.assertEqual(shipping(6000), 0)

    def test_small_orders_pay_shipping(self):
        self.assertEqual(shipping(1000), 499)


class AddressTest(unittest.TestCase):
    def test_blank_parts_are_rejected(self):
        self.assertFalse(check_address("1 High St", " ", "AB1 2CD"))

    def test_label_upper_cases_the_postcode(self):
        self.assertEqual(delivery_label("1 High St", "Leeds", "ls1 4ap"), "1 High St, Leeds LS1 4AP")


if __name__ == "__main__":
    unittest.main()
