# Provenance: @decided 2026-11-12 (paraphrased): a person approving a held tool call is shown its arguments,
# taken from the enforcement point and sealed so that only the console reads them; a decision made without
# seeing them is allowed and recorded as unseen. @claude 2026-11-12: the wiring below is wardryx 2.7.0
# (invariant 51 there) and genaryx #158 (invariant 48 there). Each scenario is bound to a teeth case by name.
Feature: The console holds the preview key, and wardryx seals each held call's arguments to it

  Scenario: the preview key is made once by the pinned console and kept
    Given a box with no preview key
    When install.sh runs, and then runs again
    Then the key is mode 0400 for the console's user, the recipient is handed to wardryx, the second run keeps the key without running the console again, and nothing prints it
    # -> gates-have-teeth.sh "preview-key-is-wired: the preview key is left readable by its group"
    # -> gates-have-teeth.sh "preview-key-is-wired: a re-run makes a new preview key"
    # -> gates-have-teeth.sh "preview-key-is-wired: the recipient is not handed to wardryx"
    # -> gates-have-teeth.sh "preview-key-is-wired: the private key is printed"
    # -> gates-have-teeth.sh "preview-key-is-wired: the mint directory is left behind"

  Scenario: a key without its recipient, or the reverse, stops the install
    Given a box that holds one half of the pair
    When install.sh runs
    Then it stops and says why, because a recipient the key does not match seals previews nobody can open
    # -> gates-have-teeth.sh "preview-key-is-wired: a half pair is repaired instead of refused"

  Scenario: a console that cannot make the key
    Given the pinned console, or an older console the operator named, that has no preview-key command
    When install.sh runs
    Then the pinned one stops the install, and the operator's one turns the preview off, says so, and drops an earlier recipient
    # -> gates-have-teeth.sh "preview-key-is-wired: a pinned console that cannot make the key turns the preview off quietly"
    # -> gates-have-teeth.sh "preview-key-is-wired: an older console keeps the recipient"

  Scenario: the private key reaches the console alone
    Given the compose file
    When it is read
    Then only the console mounts ./preview, read only, wardryx carries an empty recipient by default and is v2.7.0 or later by digest
    # -> gates-have-teeth.sh "preview-key-is-wired: the console loses its preview key mount"
    # -> gates-have-teeth.sh "preview-key-is-wired: the private preview key reaches wardryx"
    # -> gates-have-teeth.sh "preview-key-is-wired: wardryx gets a recipient by default"
    # -> gates-have-teeth.sh "preview-key-is-wired: wardryx is pinned back to 2.6.2"

  Scenario: the key directory is the console's to pass through and nobody's to list
    Given a box under any umask
    When install.sh makes the preview directory
    Then it is root's, its group the console's, mode 0710, and the key exists before the stack starts
    # -> gates-have-teeth.sh "preview-key-is-wired: the preview directory is listable by others"
    # -> gates-have-teeth.sh "preview-key-is-wired: the preview directory is not given the console's group"
    # -> gates-have-teeth.sh "preview-key-is-wired: the key is made after the stack is up"
    # -> gates-have-teeth.sh "preview-key-is-wired: a reworded comment on the preview key is not a fault"
