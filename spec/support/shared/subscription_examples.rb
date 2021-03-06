RSpec.shared_examples 'subscriptions are not supported' do
  describe '#supports_subscriptions?' do
    it 'returns false' do
      expect(subject.supports_subscriptions?).to eq(false)
    end
  end

  it { is_expected.not_to override_method(:handle_subscribe) }

  describe '#subscribe' do
    it 'raises an error' do
      destination = double('destination')
      consumer = ->(_) {}
      expect do
        subject.subscribe(destination, &consumer)
      end.to raise_error "#subscribe is not supported by #{subject.adapter.class}"
    end
  end
end

RSpec.shared_examples 'subscriptions are supported' do |subscription_type|
  describe '#supports_subscriptions?' do
    it 'returns true' do
      expect(subject.supports_subscriptions?).to eq(true)
    end
  end

  it { is_expected.to override_method(:handle_subscribe) }

  let(:destination) { adapter_context.create_destination('subscriptions_example_queue') }

  let(:message1) { 'message 1' }
  let(:message2) { 'message 2' }
  let(:messages) { [] }
  let(:consumer) do
    lambda do |msg|
      messages << msg
    end
  end

  describe '#subscribe' do
    before do
      destination.purge if destination.respond_to? :purge
    end

    let(:subscription) { adapter_context.subscribe(destination, &consumer) }
    after do
      subscription.unsubscribe
    end

    it 'returns a MessageDriver::Subscription::Base' do
      expect(subscription).to be_a MessageDriver::Subscription::Base
    end

    context 'the subscription' do
      subject { subscription }

      it { is_expected.to be_a MessageDriver::Subscription::Base }
      it { is_expected.to be_a subscription_type }

      describe '#adapter' do
        it { expect(subject.adapter).to be adapter }
      end

      describe '#destination' do
        it { expect(subject.destination).to be destination }
      end

      describe '#consumer' do
        it { expect(subject.consumer).to be consumer }
      end

      describe '#unsubscribe' do
        it "makes it so messages don't go to the consumer any more" do
          subscription.unsubscribe
          expect do
            destination.publish('should not be consumed')
          end.to_not change { messages.size }
        end
      end
    end

    context 'when there are already messages in the destination' do
      before do
        destination.publish(message1)
        destination.publish(message2)
      end

      it 'plays the messages into the consumer' do
        expect do
          subscription
          pause_if_needed
        end.to change { messages.size }.from(0).to(2)
        expect(messages.map(&:destination)).to all(be_a(MessageDriver::Destination::Base))
        bodies = messages.map(&:body)
        expect(bodies).to include(message1)
        expect(bodies).to include(message2)
      end

      it 'removes the messages from the queue' do
        pause_if_needed
        expect do
          subscription
          pause_if_needed
        end.to change { destination.message_count }.from(2).to(0)
      end
    end

    context 'when a message is published to the destination' do
      before do
        subscription
      end

      it 'consumers the message into the consumer instead of putting them on the queue' do
        expect do
          expect do
            subject.publish(destination, message1)
            pause_if_needed
          end.to change { messages.length }.from(0).to(1)
        end.to_not change { destination.message_count }
        expect(messages[0].body).to eq(message1)
      end
    end

    context 'when the consumer raises an error' do
      let(:error) { RuntimeError.new('oh nos!') }
      let(:consumer) do
        lambda do |_|
          raise error
        end
      end

      before do
        destination.publish(message1)
        destination.publish(message2)
      end

      it 'keeps processing the messages' do
        pause_if_needed
        expect do
          subscription
          pause_if_needed
        end.to change { destination.message_count }.from(2).to(0)
      end

      context 'an error_handler is provided' do
        let(:error_handler) { double(:error_handler, call: nil) }
        let(:subscription) { adapter_context.subscribe(destination, error_handler: error_handler, &consumer) }

        it 'passes the errors and the messages to the error handler' do
          subscription
          pause_if_needed
          expect(error_handler).to have_received(:call).with(error, kind_of(MessageDriver::Message::Base)).at_least(2).times
        end
      end
    end
  end
end
