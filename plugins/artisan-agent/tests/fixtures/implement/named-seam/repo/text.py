"""Text helpers for note titles."""


def title_case(title):
    """Capitalise the first letter of every word."""
    return " ".join(word[:1].upper() + word[1:] for word in title.split())
