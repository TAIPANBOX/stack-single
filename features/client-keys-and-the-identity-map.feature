# @decided 2026-10-13 (paraphrased): the installer takes the gateway's client keys and its
# identity map as files, so a person or an onboarding agent prepares the input and the
# installer applies it; it keeps them across re-runs, never rotating a secret or dropping
# the map; it checks them before anything restarts, refusing an unknown unit, an empty file
# and a map that names a key with no secret; it mounts the map read only into the gateway;
# and it ends by saying which header an agent sends. @claude 2026-10-13: the gateway image
# this box runs is the judge of the files, in a throwaway container, so the check is the
# real parser rather than a copy. Scenarios are bound to cases in scripts/gates-have-teeth.sh
# by name, and scripts/features-are-bound.sh holds the binding both ways.
Feature: the installer takes client keys and the identity map as files, and keeps them

  A client key decides who may call the gateway. The identity map decides which agent
  ids each key may speak as, and which unit pays for its calls. Both are prepared
  outside the box, by a person or by an onboarding agent, and handed to install.sh as
  files. Nothing restarts until the gateway image itself has read them, a re-run keeps
  them, and the end of the run says which headers an agent sends.

  Scenario: what install.sh writes reaches the gateway, and only the gateway
    Given the gateway reads TOKENFUSE_CLIENT_KEYS and TOKENFUSE_IDENTITY_MAP from .env
    When compose.yaml stops passing either, or hands the keys to another service
    Then identity-files-are-checked.sh fails and names what is missing or where it leaked
    # -> gates-have-teeth.sh "identity-files: the gateway loses its client keys setting"
    # -> gates-have-teeth.sh "identity-files: the gateway loses its identity map setting"
    # -> gates-have-teeth.sh "identity-files: another service is handed the client keys"

  Scenario: a box that gives no file runs exactly as before
    Given an operator who never names CLIENT_KEYS_FILE or IDENTITY_MAP_FILE
    When compose.yaml makes the keys required instead of empty by default
    Then identity-files-are-checked.sh fails, because every such box would stop starting
    # -> gates-have-teeth.sh "identity-files: the client keys become required"

  Scenario: the map is mounted read only, at the path .env names
    Given the gateway reads the map and must not be able to change it
    When the mount loses its read-only flag, or install.sh names a path outside the mount
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: the map is mounted writable"
    # -> gates-have-teeth.sh "identity-files: the map path in .env is not the file inside the mount"

  Scenario: a keys file that would put something unsafe into .env is refused before anything is installed
    Given a keys file is one secret:key_id per line, written by somebody else
    When install.sh accepts a short secret, a quote or a dollar, a secret given twice, a NUL byte, or a file of comments alone
    Then identity-files-are-checked.sh fails, because the refusal has to come before the box is touched
    # -> gates-have-teeth.sh "identity-files: the installer accepts a short secret"
    # -> gates-have-teeth.sh "identity-files: the installer lets a quote or a dollar into a secret"
    # -> gates-have-teeth.sh "identity-files: the installer keeps a secret given twice"
    # -> gates-have-teeth.sh "identity-files: a NUL byte in a file is let through"
    # -> gates-have-teeth.sh "identity-files: a keys file of comments alone is accepted"
    # -> gates-have-teeth.sh "identity-files: a map that is not a JSON object passes the first half"

  Scenario: a refusal never repeats a secret
    Given a refused keys file may hold real credentials
    When install.sh puts the offending line into its refusal
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: a refusal repeats the secret"

  Scenario: the gateway refuses what it would refuse to start on, before anything restarts
    Given the gateway image this box runs reads the pair in a throwaway container
    When install.sh stops hearing the gateway's own refusal, such as a unit the map never declares
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: the gateway's own refusal is not heard"

  Scenario: an empty map, a key with no secret and a key with no binding are refused too
    Given the gateway only warns about these three and then runs
    When install.sh accepts a map that configures nothing, a map binding a key id no secret carries, or a key the map does not bind
    Then identity-files-are-checked.sh fails, because each would leave a box that looks governed and is not
    # -> gates-have-teeth.sh "identity-files: a map that configures nothing is accepted"
    # -> gates-have-teeth.sh "identity-files: a map that binds a key with no secret is accepted"
    # -> gates-have-teeth.sh "identity-files: a client key the map does not bind is accepted"

  Scenario: a re-run keeps the keys and the map, and rotates nothing
    Given a box installed with a keys file and a map
    When install.sh runs again naming no file, and loses or rewrites what it kept
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: a re-run that names no file loses the kept keys"
    # -> gates-have-teeth.sh "identity-files: a bad key left in .env is accepted on a re-run"

  Scenario: a new file replaces what it names, and only a new map restarts the gateway
    Given an operator hands in a new keys file or a new map later
    When install.sh appends a second line, quotes nothing, restarts for the same map, or never restarts for a new one
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: a new file adds a second line instead of replacing"
    # -> gates-have-teeth.sh "identity-files: the keys are written into .env unquoted"
    # -> gates-have-teeth.sh "identity-files: the same map again restarts the gateway"
    # -> gates-have-teeth.sh "identity-files: a new map does not restart the gateway"
    # -> gates-have-teeth.sh "identity-files: the map is installed writable"

  Scenario: the check happens before anything restarts
    Given the first half needs no parser and the second needs the gateway image
    When the first half moves after a package install, or the second after the stack starts, or the second is never called
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: the files are checked after a package is installed"
    # -> gates-have-teeth.sh "identity-files: the gateway reads the files after the stack starts"
    # -> gates-have-teeth.sh "identity-files: the installer never asks the gateway image"

  Scenario: the running gateway is asked, and the end of the run names the headers
    Given section 8 asks the running gateway to refuse a call with no key and to report its map
    When that check goes, or the closing report stops naming x-fuse-key
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: section 8 stops asking the running gateway"
    # -> gates-have-teeth.sh "identity-files: the end of the run stops naming the header"

  Scenario: the gate never reports OK on nothing
    Given the gate judges the gateway services and the installer block it finds
    When no gateway service matches, or the block is renamed
    Then identity-files-are-checked.sh says it measured nothing, and does not report OK
    # -> gates-have-teeth.sh "identity-files: no gateway service left to judge"
    # -> gates-have-teeth.sh "identity-files: the installer block is gone"

  Scenario: a comment or a reworded refusal is not a fault
    Given reviewers write comments beside the settings and edit the wording of refusals
    When a comment names a required form of the setting, or a refusal is reworded
    Then identity-files-are-checked.sh still passes
    # -> gates-have-teeth.sh "identity-files: a comment that names a required setting is not the setting"
    # -> gates-have-teeth.sh "identity-files: a reworded refusal still refuses"
