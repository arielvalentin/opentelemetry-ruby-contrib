# frozen_string_literal: true

require 'active_support/subscriber'
require_relative './version'

module OpenTelemetry
  module Instrumentation
    module ActiveJob
      module Patches
        # Module to prepend to ActiveJob::Core for context propagation.
        module Base
          def self.prepended(base)
            base.class_eval do
              attr_accessor :__otel_headers
            end
          end

          def initialize(...)
            @__otel_headers = {}
            super
          end

          def serialize
            message = super

            begin
              message.merge!('__otel_headers' => serialize_arguments(@__otel_headers))
            rescue StandardError => e
              OpenTelemetry.handle_error(exception: e)
            end

            message
          end

          def deserialize(job_data)
            begin
              @__otel_headers = deserialize_arguments(job_data.delete('__otel_headers') || []).to_h
            rescue StandardError => e
              OpenTelemetry.handle_error(exception: e)
            end
            super
          end
          ::ActiveJob::Base.prepend(self)
        end
      end
    end
  end
end

module OpenTelemetry
  module Instrumentation
    module ActiveJob

      module AttributeProcessor
        def to_otel_semconv_attributes(job)
          test_adapters = %w[async inline]

          otel_attributes = {
            'code.namespace' => job.class.name,
            'messaging.destination_kind' => 'queue',
            'messaging.system' => job.class.queue_adapter_name,
            'messaging.destination' => job.queue_name,
            'messaging.message_id' => job.job_id,
            'messaging.active_job.provider_job_id' => job.provider_job_id,
            'messaging.active_job.priority' => job.priority
          }

          otel_attributes['net.transport'] = 'inproc' if test_adapters.include?(job.class.queue_adapter_name)
          otel_attributes.compact!

          otel_attributes
        end
      end

      class DefaultHandler
        include AttributeProcessor

        def initialize(tracer)
          @tracer = tracer
        end

        def on_start(name, _id, payload)
          span = @tracer.start_span(name, attributes: to_otel_semconv_attributes(payload.fetch(:job)))
          tokens = [OpenTelemetry::Context.attach(OpenTelemetry::Trace.context_with_span(span))]
          OpenTelemetry.propagation.inject(payload.fetch(:job).__otel_headers) # This must be transmitted over the wire
          { span: span, ctx_tokens: tokens }
        end
      end

      class EnqueueHandler
        include AttributeProcessor

        def initialize(tracer)
          @tracer = tracer
        end

        def on_start(name, _id, payload)
          span = @tracer.start_span("#{payload.fetch(:job).queue_name} publish",
          kind: :producer,
          attributes: to_otel_semconv_attributes(payload.fetch(:job)))
          tokens = [OpenTelemetry::Context.attach(OpenTelemetry::Trace.context_with_span(span))]
          OpenTelemetry.propagation.inject(payload.fetch(:job).__otel_headers) # This must be transmitted over the wire
          { span: span, ctx_tokens: tokens }
        end
      end

      class PerformHandler
        include AttributeProcessor

        def initialize(tracer)
          @tracer = tracer
        end

        def on_start(name, _id, payload)
          tokens = []
          parent_context = OpenTelemetry.propagation.extract(payload.fetch(:job).__otel_headers)
          span_context = OpenTelemetry::Trace.current_span(parent_context).context

          if span_context.valid?
            tokens << OpenTelemetry::Context.attach(parent_context)
            links = [OpenTelemetry::Trace::Link.new(span_context)]
          end

          span = @tracer.start_root_span(
            "#{payload.fetch(:job).queue_name} process",
            kind: :consumer,
            attributes: to_otel_semconv_attributes(payload.fetch(:job)),
            links: links
          )

          tokens << OpenTelemetry::Context.attach(
            OpenTelemetry::Trace.context_with_span(span)
          )

          { span: span, ctx_tokens: tokens }
        end
      end

      class Subscriber < ::ActiveSupport::Subscriber
        attr_reader :tracer

        def initialize(...)
          super
          tracer = OpenTelemetry.tracer_provider.tracer('otel-active_job', ::OpenTelemetry::Instrumentation::ActiveJob::VERSION)
          default_handler = DefaultHandler.new(tracer)
          @handlers_by_pattern = {
            'enqueue.active_job' => EnqueueHandler.new(tracer),
            'perform.active_job' => PerformHandler.new(tracer),
          }
          @handlers_by_pattern.default = default_handler
        end

        # The methods below are the events the Subscriber is interested in.
        def enqueue_at(...); end
        def enqueue(...); end
        def enqueue_retry(...); end
        def perform_start(...); end
        def perform(...);end
        def retry_stopped(...); end
        def discard(...); end

        def start(name, id, payload)
          begin
            payload.merge!(__otel: @handlers_by_pattern[name].on_start(name, id, payload)) # The payload is _not_ transmitted over the wire
          rescue StandardError => e
            OpenTelemetry.handle_error(exception: e)
          end

          super
        end

        def finish(_name, _id, payload)
          begin
            otel = payload.delete(:__otel)
            span = otel.fetch(:span)
            tokens = otel.fetch(:ctx_tokens)
            exception = payload[:error]
            if exception
              span.record_exception(exception)
              span.status = OpenTelemetry::Trace::Status.error
            end
          rescue StandardError => e
            OpenTelemetry.handle_error(exception: e)
          end

          super
        ensure
          begin
            span&.finish
          rescue StandardError => e
            OpenTelemetry.handle_error(exception: e)
          end
          tokens&.reverse&.each do |token|
            begin
              OpenTelemetry::Context.detach(token)
            rescue StandardError => e
              OpenTelemetry.handle_error(exception: e)
            end
          end
        end

        attach_to :active_job
      end
    end
  end
end
