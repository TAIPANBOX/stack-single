# Written from what the install already promises: it checks the gateway, the cloud and
# the console on their health paths, and then nothing watches them. Docker's own
# healthcheck is the watch that outlives the install. A service whose image has no
# tool to ask with is left out on purpose, and named as such.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: Docker watches every service that exposes a health path

  A service that goes bad after the install is restarted by compose and reported
  healthy by `docker compose ps` unless something asks it a question. Each service the
  installer probes at a health path gets a healthcheck that asks the same question.

  Scenario: a service the installer probes is watched by a healthcheck on that path
    Given the console, the cloud and the gateway, each with a health path the installer checks
    When compose reads the healthchecks
    Then each has one that asks for /healthz on the port it listens on and reads the status line
    # -> gates-have-teeth.sh "health-checks-are-declared: the console has no healthcheck"
    # -> gates-have-teeth.sh "health-checks-are-declared: the gateway probes the wrong port"
    # -> gates-have-teeth.sh "health-checks-are-declared: the console asks for a path that is not /healthz"

  Scenario: a service whose image has no tool to ask with is not given a healthcheck
    Given a distroless service with no shell, curl or wget
    When the healthcheck list is read
    Then that service has no healthcheck, and the list says why
    # -> gates-have-teeth.sh "health-checks-are-declared: a distroless service gets a healthcheck"

  Scenario: the installer keeps asking the paths the healthchecks mirror
    Given a healthcheck that watches the gateway on its health path
    When the installer stops asking that path
    Then the gate fails, because the healthcheck would watch a path nothing checks
    # -> gates-have-teeth.sh "health-checks-are-declared: the installer stops asking for the gateway's health path"

  Scenario: the list of services is read, not assumed
    Given a compose file with no services under services:
    When the healthcheck gate runs
    Then it says it measured nothing, and does not report OK
    # -> gates-have-teeth.sh "health-checks-are-declared: compose.yaml has no services to read"

  Scenario: rewording a comment does not change the healthchecks
    Given the healthcheck block with a comment reworded
    When the healthcheck gate runs
    Then it still passes
    # -> gates-have-teeth.sh "health-checks-are-declared: a comment in the healthcheck block is reworded"
