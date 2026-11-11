import unittest

import todo


class TodoTest(unittest.TestCase):
    def setUp(self):
        todo.reset()

    def test_add_then_list(self):
        todo.add("milk")
        self.assertEqual(["[ ] milk"], todo.items())


if __name__ == "__main__":
    unittest.main()
