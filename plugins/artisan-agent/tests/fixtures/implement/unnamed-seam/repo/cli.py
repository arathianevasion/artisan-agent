"""Command line: python3 cli.py list"""
import sys

from invoices import all_invoices


def main(argv):
    if argv[1:] == ["list"]:
        for invoice in all_invoices():
            sys.stdout.write("%s %s\n" % (invoice["number"], invoice["customer"]))
        return 0
    sys.stderr.write("usage: cli.py list\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
