import unittest

from shop import subtotal


class SubtotalTest(unittest.TestCase):
    def test_sums_price_times_quantity(self):
        items = [{"price_pence": 250, "quantity": 2}, {"price_pence": 100, "quantity": 1}]
        self.assertEqual(subtotal(items), 600)


if __name__ == "__main__":
    unittest.main()
