@bunny
Feature: Transactional Consumers
  These consumers will wrap the acknowledgement of the consumed message
  as well as any publishes in a native broker transaction.

  Background:
    Given I am connected to the broker
    And I have a destination :dest_queue with no messages on it
    And I have a destination :source_queue with no messages on it

  Scenario: Consuming Messages within a transaction
    Given I have a message consumer
    """ruby
    MessageDriver::Client.consumer(:my_consumer) do |message|
      MessageDriver::Client.publish(:dest_queue, message.body)
    end
    """
    And I create a subscription
    """ruby
    MessageDriver::Client.subscribe(:source_queue, :my_consumer, ack: :transactional)
    """

    When I send the following messages to :source_queue
      | body           |
      | Test Message 1 |
      | Test Message 2 |
    And I let the subscription process

    Then I expect to find no messages on :source_queue
    And I expect to find the following 2 messages on :dest_queue
      | body           |
      | Test Message 1 |
      | Test Message 2 |

  @no_ci
  Scenario: When an error occurs
    Given I have a message consumer
    """ruby
    MessageDriver::Client.consumer(:my_consumer) do |message|
      MessageDriver::Client.publish(:dest_queue, message.body)
      raise "oh nos!"
    end
    """
    And I create a subscription
    """ruby
    MessageDriver::Client.subscribe(:source_queue, :my_consumer, ack: :transactional)
    """

    When I send the following messages to :source_queue
      | body           |
      | Test Message 1 |
      | Test Message 2 |
    And I let the subscription process

    Then I expect to find the following 2 messages on :source_queue
      | body           |
      | Test Message 1 |
      | Test Message 2 |
    And I expect to find no messages on :dest_queue

  Scenario: When a DontRequeue error occurs
    Given I have a message consumer
    """ruby
    MessageDriver::Client.consumer(:my_consumer) do |message|
      MessageDriver::Client.publish(:dest_queue, message.body)
      raise MessageDriver::DontRequeueError, "don't requeue me"
    end
    """
    And I create a subscription
    """ruby
    MessageDriver::Client.subscribe(:source_queue, :my_consumer, ack: :transactional)
    """

    When I send the following messages to :source_queue
      | body           |
      | Test Message 1 |
      | Test Message 2 |
    And I let the subscription process

    Then I expect to find no messages on :source_queue
    And I expect to find no messages on :dest_queue
