require 'spec_helper'

require 'message_driver/adapters/bunny_adapter'

module MessageDriver
  module Adapters
    RSpec.describe BunnyAdapter, :bunny, type: :integration do
      let(:valid_connection_attrs) { BrokerConfig.config }

      describe '#initialize' do
        context 'differing bunny versions' do
          let(:broker) { double('broker') }
          shared_examples 'raises an error' do
            it 'raises an error' do
              stub_const('Bunny::VERSION', version)
              expect do
                described_class.new(broker, valid_connection_attrs)
              end.to raise_error MessageDriver::Error, 'bunny 1.7.0 or later is required for the bunny adapter'
            end
          end
          shared_examples "doesn't raise an error" do
            it "doesn't raise an an error" do
              stub_const('Bunny::VERSION', version)
              adapter = nil
              expect do
                adapter = described_class.new(broker, valid_connection_attrs)
              end.to_not raise_error
            end
          end
          %w(0.8.0 0.9.0 0.9.8 0.10.7 1.0.3 1.1.2 1.2.1 1.2.2 1.3.0 1.4.1 1.6.2 1.7.1 2.0.0 2.5.1 2.6.7).each do |v|
            context "bunny version #{v}" do
              let(:version) { v }
              include_examples 'raises an error'
            end
          end
          %w(2.7.4 2.8.1 2.9.2).each do |v|
            context "bunny version #{v}" do
              let(:version) { v }
              include_examples "doesn't raise an error"
            end
          end
        end

        it 'connects to the rabbit broker' do
          broker = double(:broker)
          adapter = described_class.new(broker, valid_connection_attrs)

          expect(adapter.connection).to be_a Bunny::Session
          expect(adapter.connection).to be_open
        end

        it 'connects to the rabbit broker lazily' do
          broker = double(:broker)
          adapter = described_class.new(broker, valid_connection_attrs)

          expect(adapter.connection(false)).to be_nil
        end
      end

      shared_context 'a connected bunny adapter' do
        let(:broker) { MessageDriver::Broker.configure(valid_connection_attrs) }
        subject(:adapter) { broker.adapter }
        let(:connection) { adapter.connection }

        after do
          adapter.stop
        end
      end

      shared_context 'with a queue' do
        include_context 'a connected bunny adapter'

        let(:channel) { connection.create_channel }
        let(:tmp_queue_name) { 'my_temp_queue' }
        let(:tmp_queue) { channel.queue(tmp_queue_name, exclusive: true) }
      end

      it_behaves_like 'an adapter' do
        include_context 'a connected bunny adapter'
      end

      describe '#ack_key' do
        include_context 'a connected bunny adapter'

        it 'should be :manual_ack' do
          expect(adapter.ack_key).to eq(:manual_ack)
        end
      end

      describe '#new_context' do
        include_context 'a connected bunny adapter'

        it 'returns a BunnyAdapter::BunnyContext' do
          expect(subject.new_context).to be_a BunnyAdapter::BunnyContext
        end
      end

      describe BunnyAdapter::BunnyContext do
        include_context 'a connected bunny adapter'
        subject(:adapter_context) { adapter.new_context }
        around(:example) do |ex|
          MessageDriver::Client.with_adapter_context(adapter_context) do
            ex.run
          end
        end

        after(:example) do
          adapter_context.invalidate
        end

        it_behaves_like 'an adapter context'
        it_behaves_like 'transactions are supported'
        it_behaves_like 'client acks are supported'
        it_behaves_like 'subscriptions are supported', BunnyAdapter::Subscription

        describe '#pop_message' do
          include_context 'with a queue'
          it 'needs some real tests'
        end

        describe '#invalidate' do
          it 'closes the channel' do
            subject.with_channel(false) do |ch|
              expect(ch).to be_open
            end
            subject.invalidate
            expect(subject.instance_variable_get(:@channel)).to be_closed
          end
        end

        describe '#create_destination' do
          context 'with defaults' do
            context 'the resulting destination' do
              let(:dest_name) { 'my_dest' }
              subject(:result) { adapter_context.create_destination(dest_name, exclusive: true) }

              it { is_expected.to be_a BunnyAdapter::QueueDestination }
            end
          end

          shared_examples 'supports publisher confirmations' do
            let(:properties) { { persistent: false, confirm: true } }
            it 'switches the channel to confirms mode' do
              expect(adapter_context.channel.using_publisher_confirms?).to eq(true)
            end
            it 'waits until the confirm comes in' do
              expect(adapter_context.channel.unconfirmed_set).to be_empty
            end
          end

          context 'the type is queue' do
            context 'and there is no destination name given' do
              subject(:destination) { adapter_context.create_destination('', type: :queue, exclusive: true) }
              it { is_expected.to be_a BunnyAdapter::QueueDestination }

              describe '#name' do
                it 'is a non-empty String' do
                  expect(subject.name).to be_a String
                  expect(subject.name).not_to be_empty
                end
              end
            end

            context 'the resulting destination' do
              let(:dest_name) { 'my_dest' }
              subject(:destination) { adapter_context.create_destination(dest_name, type: :queue, exclusive: true) }
              before do
                destination
              end

              it { is_expected.to be_a BunnyAdapter::QueueDestination }

              describe '#name' do
                it 'is the destination name' do
                  expect(subject.name).to be_a String
                  expect(subject.name).to eq(dest_name)
                end
              end

              include_examples 'supports #message_count'
              include_examples 'supports #consumer_count'

              it "strips off the type so it isn't set on the destination" do
                expect(subject.dest_options).to_not have_key :type
              end
              it 'ensures the queue is declared' do
                expect do
                  connection.with_channel do |ch|
                    ch.queue(dest_name, passive: true)
                  end
                end.to_not raise_error
              end
              context 'publishing a message' do
                let(:body) { 'Testing the QueueDestination' }
                let(:headers) { { 'foo' => 'bar' } }
                let(:properties) { { persistent: false } }
                before do
                  subject.publish(body, headers, properties)
                end
                it 'publishes via the default exchange' do
                  msg = subject.pop_message
                  expect(msg.body).to eq(body)
                  expect(msg.headers).to eq(headers)
                  expect(msg.properties[:delivery_mode]).to eq(1)
                  expect(msg.delivery_info.exchange).to eq('')
                  expect(msg.delivery_info.routing_key).to eq(subject.name)
                end
                include_examples 'supports publisher confirmations'
              end
              it_behaves_like 'a destination'
            end
            context 'and bindings are provided' do
              let(:dest_name) { 'binding_test_queue' }
              let(:exchange) { adapter_context.create_destination('amq.direct', type: :exchange) }

              it "raises an exception if you don't provide a source" do
                expect do
                  adapter_context.create_destination('bad_bind_queue', type: :queue, exclusive: true, bindings: [{ args: { routing_key: 'test_exchange_bind' } }])
                end.to raise_error MessageDriver::Error, /must provide a source/
              end

              it 'routes message to the queue through the exchange' do
                destination = adapter_context.create_destination(dest_name, type: :queue,
                                                                            exclusive: true,
                                                                            bindings: [{
                                                                              source: 'amq.direct',
                                                                              args: { routing_key: 'test_queue_bind' }
                                                                            }]
                                                                )
                exchange.publish('test queue bindings', {}, routing_key: 'test_queue_bind')
                message = destination.pop_message
                expect(message).to_not be_nil
                expect(message.body).to eq('test queue bindings')
              end
            end

            context 'we are not yet connected to the broker and :no_declare is provided' do
              it "doesn't cause a connection to the broker" do
                connection.stop
                adapter_context.create_destination('test_queue', no_declare: true, type: :queue, exclusive: true)
                expect(adapter.connection(false)).to_not be_open
              end

              context 'with a server-named queue' do
                it 'raises an error' do
                  expect do
                    adapter_context.create_destination('', no_declare: true, type: :queue, exclusive: true)
                  end.to raise_error MessageDriver::Error, 'server-named queues must be declared, but you provided :no_declare => true'
                end
              end

              context 'with bindings' do
                it 'raises an error' do
                  expect do
                    adapter_context.create_destination('tmp_queue', no_declare: true, bindings: [{ source: 'amq.fanout' }], type: :queue, exclusive: true)
                  end.to raise_error MessageDriver::Error, 'queues with bindings must be declared, but you provided :no_declare => true'
                end
              end
            end
          end

          context 'the type is exchange' do
            context 'the resulting destination' do
              let(:dest_name) { 'my_dest' }
              subject(:destination) { adapter_context.create_destination(dest_name, type: :exchange) }

              it { is_expected.to be_a BunnyAdapter::ExchangeDestination }
              include_examples "doesn't support #message_count"
              include_examples "doesn't support #consumer_count"

              it "strips off the type so it isn't set on the destination" do
                expect(subject.dest_options).to_not have_key :type
              end

              it 'raises an error when pop_message is called' do
                expect do
                  subject.pop_message(dest_name)
                end.to raise_error MessageDriver::Error, "You can't pop a message off an exchange"
              end

              context 'publishing a message' do
                let(:body) { 'Testing the ExchangeDestination' }
                let(:headers) { { 'foo' => 'bar' } }
                let(:properties) { { persistent: false } }
                before { connection.with_channel { |ch| ch.fanout(dest_name, auto_delete: true) } }
                let!(:queue) do
                  q = nil
                  connection.with_channel do |ch|
                    q = ch.queue('', exclusive: true)
                    q.bind(dest_name)
                  end
                  q
                end
                before do
                  subject.publish(body, headers, properties)
                end

                it 'publishes to the specified exchange' do
                  connection.with_channel do |ch|
                    q = ch.queue(queue.name, passive: true)
                    msg = q.pop
                    expect(msg[2]).to eq(body)
                    expect(msg[0].exchange).to eq(dest_name)
                    expect(msg[1][:headers]).to eq(headers)
                    expect(msg[1][:delivery_mode]).to eq(1)
                  end
                end
                include_examples 'supports publisher confirmations'
              end
            end

            context 'declaring an exchange on the broker' do
              let(:dest_name) { 'my.cool.exchange' }

              it "creates the exchange if you include 'declare' in the options" do
                exchange = adapter_context.create_destination(dest_name, type: :exchange, declare: { type: :fanout, auto_delete: true })
                queue = adapter_context.create_destination('', type: :queue, exclusive: true, bindings: [{ source: dest_name }])
                exchange.publish('test declaring exchange')
                message = queue.pop_message
                expect(message).to_not be_nil
                expect(message.body).to eq('test declaring exchange')
              end

              it "raises an error if you don't provide a type" do
                expect do
                  adapter_context.create_destination(dest_name, type: :exchange, declare: { auto_delete: true })
                end.to raise_error MessageDriver::Error, /you must provide a valid exchange type/
              end
            end

            context 'and bindings are provided' do
              let(:dest_name) { 'binding_exchange_queue' }
              let(:exchange) { adapter_context.create_destination('amq.direct', type: :exchange) }

              it "raises an exception if you don't provide a source" do
                expect do
                  adapter_context.create_destination('amq.fanout', type: :exchange, bindings: [{ args: { routing_key: 'test_exchange_bind' } }])
                end.to raise_error MessageDriver::Error, /must provide a source/
              end

              it 'routes message to the queue through the exchange' do
                adapter_context.create_destination('amq.fanout', type: :exchange, bindings: [{ source: 'amq.direct', args: { routing_key: 'test_exchange_bind' } }])
                destination = adapter_context.create_destination(dest_name, type: :queue, exclusive: true, bindings: [{ source: 'amq.fanout' }])
                exchange.publish('test exchange bindings', {}, routing_key: 'test_exchange_bind')
                message = destination.pop_message
                expect(message).to_not be_nil
                expect(message.body).to eq('test exchange bindings')
              end
            end

            context 'we are not yet connected to the broker' do
              it "doesn't cause a connection to the broker" do
                connection.stop
                adapter_context.create_destination('amq.fanout', type: :exchange)
                expect(adapter.connection(false)).to_not be_open
              end
            end
          end

          context 'the type is invalid' do
            it 'raises in an error' do
              expect do
                adapter_context.create_destination('my_dest', type: :foo_bar)
              end.to raise_error MessageDriver::Error, 'invalid destination type foo_bar'
            end
          end
        end

        describe '#subscribe' do
          context 'the destination is an ExchangeDestination' do
            let(:dest_name) { 'my_dest' }
            let(:destination) { adapter_context.create_destination(dest_name, type: :exchange) }
            let(:consumer) { ->(_) {} }

            it 'raises an error' do
              expect do
                adapter_context.subscribe(destination, &consumer)
              end.to raise_error MessageDriver::Error, /QueueDestination/
            end
          end
        end

        context 'publisher confirmations in a consumer', :aggregate_failures do
          let(:source_queue) { adapter_context.create_destination('subscriptions_example_queue') }
          let(:destination) { adapter_context.create_destination('confirms_destination_queue') }
          let(:body) { 'Testing the QueueDestination' }
          let(:headers) { { 'foo' => 'bar' } }
          let(:properties) { { persistent: false } }
          let(:error_handler) { double('error_handler', call: nil) }

          let(:subscription) { adapter_context.subscribe(source_queue, {ack: :auto, error_handler: error_handler}, &consumer) }
          let(:subscription_channel) { subscription.sub_ctx.channel }

          before do
            allow(error_handler).to receive(:call) do |err, _msg|
              puts err.inspect
            end
            destination.purge
            source_queue.purge
            subscription
            allow(subscription_channel).to receive(:wait_for_confirms).and_call_original
          end

          after do
            subscription.unsubscribe
          end

          context 'when messages are sent during the transaction' do
            let(:consumer) do
              ->(msg) do
                MessageDriver::Client.with_message_transaction(type: :confirm_and_wait) do
                  destination.publish(msg.body, msg.headers, msg.properties)
                end
              end
            end

            it 'publishes and waits for confirmation before "committing" the transaction' do
              expect {
                source_queue.publish(body, headers, properties)
                pause_if_needed
              }.to change { destination.message_count }.from(0).to(1)

              expect(subscription_channel).to be_using_publisher_confirms
              expect(subscription_channel.unconfirmed_set).to be_empty

              expect(adapter_context.channel).not_to be_using_publisher_confirms
              expect(adapter_context.channel.unconfirmed_set).to be_nil

              expect(error_handler).not_to have_received(:call)
              expect(subscription_channel).to have_received(:wait_for_confirms)
            end
          end

          context 'when no messages are sent during the transaction' do
            let(:consumer) do
              ->(msg) do
                MessageDriver::Client.with_message_transaction(type: :confirm_and_wait) do
                  # do nothing
                end
              end
            end

            it 'publishes and waits for confirmation before "committing" the transaction' do
              source_queue.publish(body, headers, properties)
              pause_if_needed

              expect(subscription.sub_ctx.channel).not_to be_using_publisher_confirms
              expect(subscription.sub_ctx.channel.unconfirmed_set).to be_nil

              expect(adapter_context.channel).not_to be_using_publisher_confirms
              expect(adapter_context.channel.unconfirmed_set).to be_nil

              expect(error_handler).not_to have_received(:call)
              expect(subscription_channel).not_to have_received(:wait_for_confirms)
            end
          end
        end

        context 'during a transaction with a transactional context' do
          let(:channel) { adapter_context.ensure_channel }
          let(:destination) { MessageDriver::Client.dynamic_destination('tx.test.queue') }
          before do
            adapter_context.ensure_transactional_channel
            destination.purge
          end

          context 'when nothing occurs' do
            it 'does not send a commit to the broker' do
              allow(channel).to receive(:tx_commit).and_call_original
              MessageDriver::Client.with_message_transaction do
              end
              expect(channel).not_to have_received(:tx_commit)
            end
          end

          context 'when a queue is declared' do
            it 'does not send a commit to the broker' do
              allow(channel).to receive(:tx_commit).and_call_original
              MessageDriver::Client.with_message_transaction do
                MessageDriver::Client.dynamic_destination('', exclusive: true)
              end
              expect(channel).not_to have_received(:tx_commit)
            end
          end

          context 'when a message is published' do
            it 'does send a commit to the broker' do
              allow(channel).to receive(:tx_commit).and_call_original
              MessageDriver::Client.with_message_transaction do
                destination.publish('test message')
              end
              expect(channel).to have_received(:tx_commit).once
              expect(destination.message_count).to eq(1)
            end
          end

          context 'when a message is popped' do
            it 'does not send a commit to the broker' do
              destination.publish('test message')
              allow(channel).to receive(:tx_commit).and_call_original
              MessageDriver::Client.with_message_transaction do
                msg = destination.pop_message(client_ack: true)
                expect(msg).not_to be_nil
                expect(msg.body).to eq('test message')
              end
              expect(channel).not_to have_received(:tx_commit)
            end
          end

          context 'when a message is acked' do
            it 'does send a commit to the broker' do
              destination.publish('test message')
              allow(channel).to receive(:tx_commit).and_call_original
              MessageDriver::Client.with_message_transaction do
                msg = destination.pop_message(client_ack: true)
                expect(msg).not_to be_nil
                expect(msg.body).to eq('test message')
                msg.ack
              end
              expect(channel).to have_received(:tx_commit).once
              expect(destination.message_count).to eq(0)
            end
          end

          context 'when a message is nacked' do
            it 'does send a commit to the broker' do
              destination.publish('test message')
              allow(channel).to receive(:tx_commit).and_call_original
              MessageDriver::Client.with_message_transaction do
                msg = destination.pop_message(client_ack: true)
                expect(msg).not_to be_nil
                expect(msg.body).to eq('test message')
                msg.nack
              end
              expect(channel).to have_received(:tx_commit).once
              expect(destination.message_count).to eq(1)
            end
          end
        end
      end
    end
  end
end
