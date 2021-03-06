@all_adapters
Feature: Logging

  You can configure the logger by setting it on `MessageDriver.logger`.
  If you don't provide a logger, then an info level logger will be created
  and sent to `STDOUT`.

  Scenario: Starting the broker
    Given I am logging to a log file at the debug level
    And I am connected to the broker

    Then the log file should contain:
    """
    MessageDriver configured successfully!
    """
