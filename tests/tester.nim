# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import testscommon

# suits imports
import ttaskdeps
import tnimbinaries
import taddcommand
import tinitcommand
import tcheckcommand
import tcleancommand
import tdevelopfeature
import tissues
import tlocaldeps
import tlockfile
import tmisctests
import tmoduletests
import tmultipkgs
import tnimbledump
import tnimblerefresh
import tnimbletasks
import tnimscript
import tshellenv
import tpathcommand
import treversedeps
import truncommand
import tsetupcommand
import ttestcommand
import ttwobinaryversions
import toffline
import tuninstall
import tsat
import tver
import tversiondiscovery
import tniminstall
import trequireflag
import tdeclarativeparser
import tforgeinstall
import tforgeparser
import tfilepathrequires
import tglobalinstall
import tasynctools
import tbuildinstall
import tpublish

# The standalone PubGrub library. Its suite lives next to the library in
# `pubgrub/tests/`, so that `pubgrub/` stays a package that can be lifted out
# as-is; `pubgrub/tester` only pulls it in. It can also be run on its own,
# which is what to do while working on the solver:
#   cd tests/pubgrub && nim c -r tester
import ./pubgrub/tester

# # nonim tests are very slow and (often) break the CI.

# # import tnonim
