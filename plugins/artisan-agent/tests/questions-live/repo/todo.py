"""A tiny todo list kept in memory."""

_items = []


def add(text):
    _items.append({"text": text, "done": False})


def items():
    return [("[x] " if i["done"] else "[ ] ") + i["text"] for i in _items]


def reset():
    _items.clear()
