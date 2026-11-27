#!/bin/sh
# Fake man and help for hint flags tests: fake_doc.sh DIR NAME prints
# DIR/NAME.txt, or exits 16 (man's "no page") when there is none.
[ -f "$1/$2.txt" ] && exec cat "$1/$2.txt"
exit 16
