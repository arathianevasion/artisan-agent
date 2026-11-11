import unittest

from text import title_case


class TitleCaseTest(unittest.TestCase):
    def test_capitalises_each_word(self):
        self.assertEqual(title_case("weekly plan"), "Weekly Plan")


if __name__ == "__main__":
    unittest.main()
