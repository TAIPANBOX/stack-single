# @claude 2026-10-14. No decision of the owner's is behind this one: it comes
# from a defect, so it opens with the defect instead. @measured on macOS
# 2026-10-14: the pre-push hook hung in scripts/delegation-key-reused-on-rerun.sh,
# whose copy of the secret generator was `LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom
# | head -c N`; run with SIGPIPE ignored, as git runs a hook, that line and
# install.sh's own gen were killed by a 5 s alarm, and in debian:12-slim install.sh's
# gen printed "tr: write error: Broken pipe". Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name, and scripts/features-are-bound.sh holds the
# binding both ways.
Feature: a secret is minted whatever SIGPIPE is set to

  install.sh mints every credential a box has with one generator, and the gates
  mint theirs with the same one. A person pushing from a Mac runs those gates in
  git's pre-push hook, where SIGPIPE is ignored. Minting a secret has to end on its
  own there, at once, and print nothing but the secret.

  Scenario: a secret is minted at once with SIGPIPE ignored
    Given install.sh's generator
    When it is run with SIGPIPE ignored, for every length install.sh asks it for
    Then each run ends at once with that many characters of A-Za-z0-9 and nothing on stderr
    # -> gates-have-teeth.sh "gen-is-bounded: install.sh's gen reads /dev/urandom with no bound again"
    # -> gates-have-teeth.sh "gen-is-bounded: the read is too small for the longest secret"

  Scenario: no gate keeps a copy of the generator that can drift from it
    Given a gate that mints keys the way install.sh does
    When it carries its own unbounded copy, or install.sh's generator can no longer be lifted
    Then the gate fails and names the file, or says it measured nothing
    # -> gates-have-teeth.sh "gen-is-bounded: a gate mints with its own unbounded copy again"
    # -> gates-have-teeth.sh "delegation-key-reused-on-rerun: install.sh's gen has no markers to lift it by"

  Scenario: any reader that would run to the end of the random stream is refused
    Given /dev/urandom, which never ends
    When it is read by anything other than head -c with a count, cat included
    Then the gate fails, while a comment or a message that only names the file still passes
    # -> gates-have-teeth.sh "gen-is-bounded: the urandom read goes through cat"
    # -> gates-have-teeth.sh "gen-is-bounded: a message names /dev/urandom"
    # -> gates-have-teeth.sh "gen-is-bounded: a comment names the unbounded idiom"
    # -> gates-have-teeth.sh "gen-is-bounded: the read gets larger"

  Scenario: what comes out is a secret
    Given the generator, run many times
    When it prints the same value twice, or a character outside A-Za-z0-9
    Then the gate fails
    # -> gates-have-teeth.sh "gen-is-bounded: gen prints the same value every time"
    # -> gates-have-teeth.sh "gen-is-bounded: gen leaves the alphabet"

  Scenario: the gate does not report OK on nothing
    Given install.sh with no generator, or no secret asked of it
    When the gate runs
    Then it fails and says it measured nothing
    # -> gates-have-teeth.sh "gen-is-bounded: install.sh defines no gen"
    # -> gates-have-teeth.sh "gen-is-bounded: install.sh asks gen for no length"
