import unittest

from invoices import all_invoices


class InvoicesTest(unittest.TestCase):
    def test_lists_every_invoice(self):
        self.assertEqual([i["number"] for i in all_invoices()], ["INV-001", "INV-002"])


if __name__ == "__main__":
    unittest.main()
