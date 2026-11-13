# The first test finishes last under -j; results must still print first.
test_a_slow() { sleep 1; }
test_b_fast() { :; }
test_c_fails_fast() { fail "fast failure"; }
