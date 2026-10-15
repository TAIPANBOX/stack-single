# @claude 2026-10-15: a box that ran WITH_TYPED=1 runs the typed plane on its stub
# backend. Until this, the installer did not write that choice down, so a plain
# re-run read no mode and turned the plane off. Scenarios are bound by name to
# cases in scripts/gates-have-teeth.sh.
Feature: a plain re-run keeps the typed mode the box runs, the stub included

  The README promises that an existing box keeps its mode on a re-run. For the
  stub that promise was false: WITH_TYPED=1 was never saved, so the next
  ./install.sh with nothing set took the typed plane away.

  Scenario: WITH_TYPED=1 records the stub
    Given a box whose .env holds no TYPED_MODE
    When the installer runs with WITH_TYPED=1
    Then .env holds TYPED_MODE='stub' and the plane is the stub
    # -> gates-have-teeth.sh "typed-data-mode: WITH_TYPED=1 stops recording the stub"

  Scenario: a plain re-run keeps the stub
    Given a box whose .env holds TYPED_MODE='stub'
    When the installer runs with nothing set
    Then the plane is still the stub, the risk signal stays as it was, and .env is unchanged
    # -> gates-have-teeth.sh "typed-data-mode: a plain re-run forgets a saved stub"
    # -> gates-have-teeth.sh "typed-risk-signal: a plain re-run of the stub turns the signal off"

  Scenario: an explicit TYPED_MODE=off turns the stub off, and it stays off
    Given a box whose .env holds TYPED_MODE='stub'
    When the installer runs with TYPED_MODE=off
    Then the plane is off, TYPED_MODE='off' is recorded, and a plain re-run keeps it off
    # -> gates-have-teeth.sh "typed-data-mode: an explicit TYPED_MODE=off does not stick over a stub"

  Scenario: jev and own-model still survive a plain re-run
    Given a box whose .env holds TYPED_MODE='jev' or TYPED_MODE='own-model'
    When the installer runs with nothing set, or with only a new TYPED_MODEL_URL
    Then that mode is kept, and the lines it owns are not rewritten
    # -> gates-have-teeth.sh "typed-data-mode: a re-run forgets the saved mode"
    # -> gates-have-teeth.sh "typed-data-mode: a re-run forgets a saved own-model"
