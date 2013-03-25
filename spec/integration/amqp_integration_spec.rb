require 'spec_helper'

describe "AMQP Integration", :bunny, type: :integration do
  before do
    MessageDriver.configure BrokerConfig.config
  end

  context "when a queue can't be found" do
    let(:queue_name) { "my.lost.queue" }
    it "raises a MessageDriver::QueueNotFound error" do
      expect {
        MessageDriver::Broker.dynamic_destination(queue_name, passive: true)
      }.to raise_error(MessageDriver::QueueNotFound, /#{queue_name}/) do |err|
        expect(err.queue_name).to eq(queue_name)
        expect(err.other).to be_a Bunny::NotFound
      end
    end
  end

  context "when a channel level exception occurs" do
    it "raises a MessageDriver::WrappedException error" do
      expect {
        MessageDriver::Broker.dynamic_destination("not.a.queue", passive: true)
      }.to raise_error(MessageDriver::WrappedException) { |err| err.other.should be_a Bunny::ChannelLevelException }
    end

    it "reestablishes the channel transparently" do
      expect {
        MessageDriver::Broker.dynamic_destination("not.a.queue", passive: true)
      }.to raise_error(MessageDriver::WrappedException)
      expect {
        MessageDriver::Broker.dynamic_destination("", exclusive: true)
      }.to_not raise_error
    end

    context "when in a transaction" do
      it "sets the channel_context as rollback-only until the transaction is finished" do
        MessageDriver::Broker.with_transaction do
          expect {
            MessageDriver::Broker.dynamic_destination("not.a.queue", passive: true)
          }.to raise_error(MessageDriver::WrappedException)
          expect {
            MessageDriver::Broker.dynamic_destination("", exclusive: true)
          }.to raise_error(MessageDriver::TransactionRollbackOnly)
        end
        expect {
          MessageDriver::Broker.dynamic_destination("", exclusive: true)
        }.to_not raise_error
      end
    end
  end

  context "when an unhandled expection occurs in a transaction" do
    let(:destination) { MessageDriver::Broker.dynamic_destination("", exclusive: true) }

    it "rolls back the transaction" do
      expect {
        MessageDriver::Broker.with_transaction do
          destination.publish("Test Message")
          raise "unhandled error"
        end
      }.to raise_error "unhandled error"
      expect(destination.pop_message).to be_nil
    end

    it "allows the next transaction to continue" do
      expect {
        MessageDriver::Broker.with_transaction do
          destination.publish("Test Message 1")
          raise "unhandled error"
        end
      }.to raise_error "unhandled error"
      expect(destination.pop_message).to be_nil

      MessageDriver::Broker.with_transaction do
        destination.publish("Test Message 2")
      end

      msg = destination.pop_message
      expect(msg).to_not be_nil
      expect(msg.body).to eq("Test Message 2")
    end
  end
end
