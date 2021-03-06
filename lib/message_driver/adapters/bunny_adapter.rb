require 'bunny'
require 'forwardable'

module MessageDriver
  class Broker
    def bunny_adapter
      MessageDriver::Adapters::BunnyAdapter
    end
  end

  module Adapters
    class BunnyAdapter < Base
      NETWORK_ERRORS = [Bunny::TCPConnectionFailed,
                        Bunny::ConnectionClosedError,
                        Bunny::ConnectionLevelException,
                        Bunny::NetworkErrorWrapper,
                        Bunny::NetworkFailure,
                        IOError].freeze

      class Message < MessageDriver::Message::Base
        attr_reader :delivery_info

        def initialize(ctx, delivery_info, properties, payload, destination)
          raw_body = payload
          raw_headers = properties[:headers]
          raw_headers = {} if raw_headers.nil?
          b, h, p = destination.middleware.on_consume(payload, raw_headers, properties)
          super(ctx, destination, b, h, p, raw_body)
          @delivery_info = delivery_info
        end

        def delivery_tag
          delivery_info.delivery_tag
        end

        def redelivered?
          delivery_info.redelivered?
        end
      end

      class Destination < MessageDriver::Destination::Base
        def publish_params(body, headers, properties)
          b, h, p = middleware.on_publish(body, headers, properties)
          props = @message_props.merge(p)
          props[:headers] = h if h
          [b, exchange_name, routing_key(properties), props]
        end

        def exchange_name
          @name
        end

        def routing_key(properties)
          properties[:routing_key]
        end
      end

      class QueueDestination < Destination
        def after_initialize(adapter_context)
          if @dest_options[:no_declare]
            if @name.empty?
              raise MessageDriver::Error, 'server-named queues must be declared, but you provided :no_declare => true'
            end
            if @dest_options[:bindings]
              raise MessageDriver::Error, 'queues with bindings must be declared, but you provided :no_declare => true'
            end
          else
            adapter_context.with_channel(false) do |ch|
              bunny_queue(ch, init: true)
            end
          end
        end

        def bunny_queue(channel, options = {})
          opts = @dest_options.dup
          opts[:passive] = options[:passive] if options.key? :passive
          queue = channel.queue(@name, opts)
          handle_queue_init(queue) if options.fetch(:init, false)
          queue
        end

        def handle_queue_init(queue)
          @name = queue.name
          if (bindings = @dest_options[:bindings])
            bindings.each do |bnd|
              raise MessageDriver::Error, "binding #{bnd.inspect} must provide a source!" unless bnd[:source]
              queue.bind(bnd[:source], bnd[:args] || {})
            end
          end
        end

        def exchange_name
          ''
        end

        def routing_key(_properties)
          @name
        end

        def handle_message_count
          current_adapter_context.with_channel(false) do |ch|
            bunny_queue(ch, passive: true).message_count
          end
        end

        def subscribe(options = {}, &consumer)
          current_adapter_context.subscribe(self, options, &consumer)
        end

        def handle_consumer_count
          current_adapter_context.with_channel(false) do |ch|
            bunny_queue(ch, passive: true).consumer_count
          end
        end

        def purge
          current_adapter_context.with_channel(false) do |ch|
            bunny_queue(ch).purge
          end
        end
      end

      class ExchangeDestination < Destination
        def after_initialize(adapter_context)
          if (declare = @dest_options[:declare])
            adapter_context.with_channel(false) do |ch|
              type = declare.delete(:type)
              raise MessageDriver::Error, 'you must provide a valid exchange type' unless type
              ch.exchange_declare(@name, type, declare)
            end
          end
          if (bindings = @dest_options[:bindings])
            adapter_context.with_channel(false) do |ch|
              bindings.each do |bnd|
                raise MessageDriver::Error, "binding #{bnd.inspect} must provide a source!" unless bnd[:source]
                ch.exchange_bind(bnd[:source], @name, bnd[:args] || {})
              end
            end
          end
        end
      end

      class Subscription < Subscription::Base
        attr_reader :sub_ctx, :error_handler

        def start
          unless destination.is_a? QueueDestination
            raise MessageDriver::Error,
                  'subscriptions are only supported with QueueDestinations'
          end
          @sub_ctx = adapter.new_subscription_context(self)
          @error_handler = options[:error_handler]
          @message_handler =  case options.delete(:ack)
                              when :auto, nil
                                AutoAckHandler.new(self)
                              when :manual
                                ManualAckHandler.new(self)
                              when :transactional
                                TransactionalAckHandler.new(self)
                              else
                                raise MessageDriver::Error, "unrecognized :ack option #{options[:ack]}"
                              end
          start_subscription
        end

        def unsubscribe
          unless @bunny_consumer.nil?
            @bunny_consumer.cancel
            @bunny_consumer = nil
          end
          unless @sub_ctx.nil?
            @sub_ctx.invalidate(true)
            @sub_ctx = nil
          end
        end

        private

        class MessageHandler
          extend Forwardable
          include Logging

          attr_accessor :subscription
          def_delegators :subscription, :adapter, :sub_ctx, :consumer, :error_handler, :options, :destination

          def initialize(subscription)
            @subscription = subscription
          end

          def call(*message_args)
            message = sub_ctx.args_to_message(*message_args, destination)
            consumer.call(message)
          rescue => e
            error_handler.call(e, message) unless error_handler.nil?
          end

          def nack_message(e, message)
            return if message.nil?
            requeue = true
            if e.is_a?(DontRequeue) || (options[:retry_redelivered] == false && message.redelivered?)
              requeue = false
            end
            if !sub_ctx.nil? && sub_ctx.valid?
              begin
                sub_ctx.nack_message(message, requeue: requeue)
              rescue => e
                logger.error exception_to_str(e)
              end
            end
          end
        end

        class ManualAckHandler < MessageHandler
          # all functionality implemented in super class
        end

        class AutoAckHandler < MessageHandler
          def call(*message_args)
            message = sub_ctx.args_to_message(*message_args, destination)
            consumer.call(message)
            sub_ctx.ack_message(message)
          rescue => e
            nack_message(e, message)
            error_handler.call(e, message) unless error_handler.nil?
          end
        end

        class TransactionalAckHandler < MessageHandler
          def call(*message_args)
            message = sub_ctx.args_to_message(*message_args, destination)
            adapter.broker.client.with_message_transaction do
              consumer.call(message)
              sub_ctx.ack_message(message)
            end
          rescue => e
            nack_message(e, message)
            error_handler.call(e, message) unless error_handler.nil?
          end
        end

        def start_subscription
          @sub_ctx.with_channel do |ch|
            queue = destination.bunny_queue(@sub_ctx.channel)
            ch.prefetch(options[:prefetch_size]) if options.key? :prefetch_size
            sub_opts = options.merge(adapter.ack_key => true)
            @bunny_consumer = queue.subscribe(sub_opts) do |delivery_info, properties, payload|
              adapter.broker.client.with_adapter_context(@sub_ctx) do
                @message_handler.call(delivery_info, properties, payload)
              end
            end
          end
        end
      end

      def initialize(broker, config)
        validate_bunny_version
        @broker = broker
        @config = config
        @ack_key = :manual_ack
      end

      attr_reader :ack_key

      def connection(ensure_started = true)
        if ensure_started
          begin
            @connection ||= Bunny::Session.new(@config)
            @connection.start
          rescue *NETWORK_ERRORS => e
            raise MessageDriver::ConnectionError.new(e.to_s, e)
          rescue => e
            stop
            raise e
          end
        end
        @connection
      end

      def stop
        super
        @connection.close unless @connection.nil?
      rescue => e
        logger.error "error while attempting connection close\n#{exception_to_str(e)}"
      ensure
        @connection = nil
      end

      def build_context
        BunnyContext.new(self)
      end

      def new_subscription_context(subscription)
        ctx = new_context
        ctx.channel = connection.create_channel
        ctx.subscription = subscription
        ctx
      end

      class BunnyContext < ContextBase
        attr_accessor :channel, :subscription

        def initialize(adapter)
          super(adapter)
          @is_transactional = false
          @rollback_only = false
          @need_channel_reset = false
          @in_transaction = false
          @require_commit = false
        end

        def handle_create_destination(name, dest_options = {}, message_props = {})
          dest =  case type = dest_options.delete(:type)
                  when :exchange
                    ExchangeDestination.new(adapter, name, dest_options, message_props)
                  when :queue, nil
                    QueueDestination.new(adapter, name, dest_options, message_props)
                  else
                    raise MessageDriver::Error, "invalid destination type #{type}"
                  end
          dest.after_initialize(self)
          dest
        end

        def supports_transactions?
          true
        end

        def handle_begin_transaction(options = {})
          if in_transaction?
            raise MessageDriver::TransactionError,
                  "you can't begin another transaction, you are already in one!"
          end
          @in_transaction = true
          @in_confirms_transaction = true if options[:type] == :confirm_and_wait
        end

        def handle_commit_transaction(_ = nil)
          if !in_transaction? && !@require_commit
            raise MessageDriver::TransactionError,
                  "you can't finish the transaction unless you already in one!"
          end
          begin
            if @in_confirms_transaction
              @channel.wait_for_confirms unless @rollback_only || @channel.nil? || !@channel.using_publisher_confirms?
            elsif is_transactional? && valid? && !@need_channel_reset && @require_commit
              handle_errors do
                if @rollback_only
                  @channel.tx_rollback
                else
                  @channel.tx_commit
                end
              end
            end
          ensure
            @rollback_only = false
            @in_transaction = false
            @in_confirms_transaction = false
            @require_commit = false
          end
        end

        def handle_rollback_transaction(_ = nil)
          @rollback_only = true
          commit_transaction
        end

        def transactional?
          @is_transactional
        end
        alias is_transactional? transactional?

        def in_transaction?
          @in_transaction
        end

        def handle_publish(destination, body, headers = {}, properties = {})
          body, exchange, routing_key, props = *destination.publish_params(body, headers, properties)
          confirm = props.delete(:confirm)
          confirm = false if confirm.nil?
          with_channel(true) do |ch|
            if confirm == true
              ch.confirm_select unless ch.using_publisher_confirms?
            end
            ch.basic_publish(body, exchange, routing_key, props)
            ch.wait_for_confirms if confirm == true
          end
        end

        def handle_pop_message(destination, options = {})
          raise MessageDriver::Error, "You can't pop a message off an exchange" if destination.is_a? ExchangeDestination

          with_channel(false) do |ch|
            queue = ch.queue(destination.name, passive: true)

            message = queue.pop(adapter.ack_key => options.fetch(:client_ack, false))
            if message.nil? || message[0].nil?
              nil
            else
              args_to_message(*message, destination)
            end
          end
        end

        def supports_client_acks?
          true
        end

        def handle_ack_message(message, _options = {})
          with_channel(true) do |ch|
            ch.ack(message.delivery_tag)
          end
        end

        def handle_nack_message(message, options = {})
          requeue = options.fetch(:requeue, true)
          with_channel(true) do |ch|
            ch.reject(message.delivery_tag, requeue)
          end
        end

        def supports_subscriptions?
          true
        end

        def handle_subscribe(destination, options = {}, &consumer)
          sub = Subscription.new(adapter, destination, consumer, options)
          sub.start
          sub
        end

        def handle_message_count(destination)
          if destination.respond_to?(:handle_message_count)
            destination.handle_message_count
          else
            super
          end
        end

        def handle_consumer_count(destination)
          if destination.respond_to?(:handle_consumer_count)
            destination.handle_consumer_count
          else
            super
          end
        end

        def invalidate(in_unsubscribe = false)
          super()
          unless @subscription.nil? || in_unsubscribe
            begin
              @subscription.unsubscribe if adapter.connection.open?
            rescue => e
              logger.debug "error trying to end subscription\n#{exception_to_str(e)}"
            end
          end
          unless @channel.nil?
            begin
              @channel.close if @channel.open? && adapter.connection.open?
            rescue => e
              logger.debug "error trying to close channel\n#{exception_to_str(e)}"
            ensure
              begin @channel.maybe_kill_consumer_work_pool! rescue nil; end
            end
          end
        end

        def handle_errors
          yield
        rescue Bunny::ChannelLevelException => e
          @need_channel_reset = true
          @rollback_only = true if in_transaction?
          if e.is_a? Bunny::NotFound
            raise MessageDriver::QueueNotFound.new(e.to_s, e)
          else
            raise MessageDriver::WrappedError.new(e.to_s, e)
          end
        rescue Bunny::ChannelAlreadyClosed => e
          @need_channel_reset = true
          @rollback_only = true if in_transaction?
          raise MessageDriver::WrappedError.new(e.to_s, e)
        rescue *NETWORK_ERRORS => e
          @need_channel_reset = true
          @rollback_only = true if in_transaction?
          raise MessageDriver::ConnectionError.new(e.to_s, e)
        end

        def ensure_channel
          @channel = adapter.connection.create_channel if @channel.nil?
          reset_channel if @need_channel_reset
          @channel
        end

        def ensure_transactional_channel
          ensure_channel
          make_channel_transactional
        end

        def make_channel_transactional
          unless is_transactional?
            @channel.tx_select
            @is_transactional = true
          end
        end

        def with_channel(require_commit = true)
          raise MessageDriver::TransactionRollbackOnly if @rollback_only
          raise MessageDriver::Error, 'this adapter context is not valid!' unless valid?
          ensure_channel
          @require_commit ||= require_commit
          if in_transaction?
            if @in_confirms_transaction
              @channel.confirm_select unless @channel.using_publisher_confirmations?
            else
              make_channel_transactional
            end
          end
          handle_errors do
            result = yield @channel
            commit_transaction if require_commit && is_transactional? && !in_transaction?
            result
          end
        end

        def args_to_message(delivery_info, properties, payload, destination)
          Message.new(self, delivery_info, properties, payload, destination)
        end

        private

        def reset_channel
          unless @channel.open?
            @channel = adapter.connection.create_channel
            @is_transactional = false
            @rollback_only = true if in_transaction?
            @require_commit
          end
          @need_channel_reset = false
        end
      end

      private

      def log_errors
        yield
      rescue => e
        logger.error exception_to_str(e)
      end

      def validate_bunny_version
        required = Gem::Requirement.create('>= 2.7.0')
        current = Gem::Version.create(Bunny::VERSION)
        unless required.satisfied_by? current
          raise MessageDriver::Error, 'bunny 1.7.0 or later is required for the bunny adapter'
        end
      end
    end
  end
end
