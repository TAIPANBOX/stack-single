# Provenance: @decided 2026-10-19 (paraphrased), found on a live install of stack-single 1.3.1.
# Each scenario is bound to a teeth case by name.
Feature: The console's first sign-in password is never printed

  Scenario: the password goes to one private file, and the closing report names the file, not the password
    Given install.sh creates the console operator on a fresh box
    When the closing report is printed
    Then it names the file and the one command that reads it, and the password is in neither
    # -> gates-have-teeth.sh "console-password-is-not-printed: the closing report names the value again"
    # -> gates-have-teeth.sh "console-password-is-not-printed: the helper prints the password it writes"

  Scenario: the password file is private from the moment it exists
    Given the helper writes the password file
    When the file is created
    Then it is made under umask 077 and is 0600, so no other local user can read it in between
    # -> gates-have-teeth.sh "console-password-is-not-printed: the password file is made without umask 077"
    # -> gates-have-teeth.sh "console-password-is-not-printed: the password file is not set 0600"

  Scenario: the console reads the password from the file, never from an argument list
    Given set-password is run for the operator
    When the password is handed over
    Then it arrives on standard input from the file, and no process's argument list carries it
    # -> gates-have-teeth.sh "console-password-is-not-printed: set-password takes the password on an argument list"
