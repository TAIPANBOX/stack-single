# @decided 2026-10-18 (paraphrased, wave 2, the key custody of design section 2.5): the
# root key that wraps Keyryx's private keys is a file, written once by the installer and
# mounted read only into the one process that uses it. It is never a value in .env or in
# any service's environment. Each scenario is bound by name to a case in
# scripts/gates-have-teeth.sh.
Feature: the Keyryx root key is a file, never an environment value

  A root key that reaches .env or an environment would be shown by any dump of either.
  So the installer writes it as a file and the compose file only names its path.

  Scenario: the installer writes a root key into .env
    Given the installer writes the two root keys as files
    When one of the functions that writes them also adds a line to .env
    Then the gate fails and names the root key that reached .env
    # -> gates-have-teeth.sh "keyryx-root: a root key is written into .env"

  Scenario: custody reads its root key from a variable interpolated from .env
    Given custody reads its root key from the file at its path
    When the compose file gives custody a root key variable taken from .env
    Then the gate fails and names the variable
    # -> gates-have-teeth.sh "keyryx-root: custody interpolates its root key from .env"

  Scenario: a reworded comment in the installer is not a fault
    Given the gate reads what the installer does to .env, not its comments
    When a comment above the root key function is reworded
    Then the gate still passes
    # -> gates-have-teeth.sh "keyryx-root: a reworded comment in install.sh is not a fault"
