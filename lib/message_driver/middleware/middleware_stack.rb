module MessageDriver
  module Middleware
    class MiddlewareStack
      include Enumerable

      attr_reader :destination

      def initialize(destination)
        @destination = destination
        @middlewares = []
      end

      def middlewares
        @middlewares.dup.freeze
      end

      def append(middleware_class, *args)
        middleware = build_middleware(middleware_class, *args)
        @middlewares << middleware
        middleware
      end

      def prepend(middleware_class, *args)
        middleware = build_middleware(middleware_class, *args)
        @middlewares.unshift middleware
        middleware
      end

      def on_publish(body, headers, properties)
        @middlewares.reduce([body, headers, properties]) do |args, middleware|
          middleware.on_publish(*args)
        end
      end

      def on_consume(body, headers, properties)
        @middlewares.reverse_each.reduce([body, headers, properties]) do |args, middleware|
          middleware.on_consume(*args)
        end
      end

      def empty?
        @middlewares.empty?
      end

      def each
        @middlewares.each { |x| yield x }
      end

      private

      def build_middleware(middleware_type, *args)
        case middleware_type
        when Hash
          BlockMiddleware.new(destination, middleware_type)
        else
          middleware_type.new(destination, *args)
        end
      end
    end
  end
end
