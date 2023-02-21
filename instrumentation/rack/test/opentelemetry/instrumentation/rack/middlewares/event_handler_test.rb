# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'
require_relative '../../../../../lib/opentelemetry/instrumentation/rack'
require_relative '../../../../../lib/opentelemetry/instrumentation/rack/instrumentation'
require_relative '../../../../../lib/opentelemetry/instrumentation/rack/middlewares/event_handler'

describe 'OpenTelemetry::Instrumentation::Rack::Middlewares::EventHandler' do
  include Rack::Test::Methods

  let(:exporter) { EXPORTER }
  let(:finished_spans) { exporter.finished_spans }
  let(:first_span) { exporter.finished_spans.first }
  let(:uri) { '/' }
  let(:handler) do
    OpenTelemetry::Instrumentation::Rack::Middlewares::EventHandler.new(
      untraced_endpoints: untraced_endpoints,
      untraced_callable: untraced_callable,
      allowed_request_headers: allowed_request_headers,
      allowed_response_headers: allowed_response_headers,
      url_quantization: url_quantization,
      response_propagators: response_propagators,
      record_frontend_span: record_frontend_span
    )
  end

  let(:service) do
    ->(_arg) { [200, { 'Content-Type' => 'text/plain' }, 'Hello World'] }
  end
  let(:untraced_endpoints) { [] }
  let(:untraced_callable) { nil }
  let(:allowed_request_headers) { nil }
  let(:allowed_response_headers) { nil }
  let(:record_frontend_span) { false }
  let(:response_propagators) { nil }
  let(:url_quantization) { nil }
  let(:headers) { {} }
  let(:app) do
    Rack::Builder.new.tap do |builder|
      builder.use Rack::Events, [handler]
      builder.run service
    end
  end

  before do
    exporter.reset
  end

  describe '#call' do
    before do
      get uri, {}, headers
    end

    it 'records attributes' do
      _(first_span.attributes['http.method']).must_equal 'GET'
      _(first_span.attributes['http.status_code']).must_equal 200
      _(first_span.attributes['http.target']).must_equal '/'
      _(first_span.attributes['http.url']).must_be_nil
      _(first_span.name).must_equal 'HTTP GET'
      _(first_span.kind).must_equal :server
    end

    it 'does not explicitly set status OK' do
      _(first_span.status.code).must_equal OpenTelemetry::Trace::Status::UNSET
    end

    it 'has no parent' do
      _(first_span.parent_span_id).must_equal OpenTelemetry::Trace::INVALID_SPAN_ID
    end

    describe 'when a query is passed in' do
      let(:uri) { '/endpoint?query=true' }

      it 'records the query path' do
        _(first_span.attributes['http.target']).must_equal '/endpoint?query=true'
        _(first_span.name).must_equal 'HTTP GET'
      end
    end

    describe 'config[:untraced_endpoints]' do
      describe 'when an array is passed in' do
        let(:untraced_endpoints) { ['/ping'] }

        it 'does not trace paths listed in the array' do
          get '/ping'

          ping_span = finished_spans.find { |s| s.attributes['http.target'] == '/ping' }
          _(ping_span).must_be_nil

          root_span = finished_spans.find { |s| s.attributes['http.target'] == '/' }
          _(root_span).wont_be_nil
        end
      end

      describe 'when a string is passed in' do
        let(:untraced_endpoints) { '/ping' }

        it 'does not trace path' do
          get '/ping'

          ping_span = finished_spans.find { |s| s.attributes['http.target'] == '/ping' }
          _(ping_span).must_be_nil

          root_span = finished_spans.find { |s| s.attributes['http.target'] == '/' }
          _(root_span).wont_be_nil
        end
      end

      describe 'when nil is passed in' do
        let(:config) { { untraced_endpoints: nil } }

        it 'traces everything' do
          get '/ping'

          ping_span = finished_spans.find { |s| s.attributes['http.target'] == '/ping' }
          _(ping_span).wont_be_nil

          root_span = finished_spans.find { |s| s.attributes['http.target'] == '/' }
          _(root_span).wont_be_nil
        end
      end
    end

    describe 'config[:untraced_requests]' do
      describe 'when a callable is passed in' do
        let(:untraced_callable) do
          ->(env) { env['PATH_INFO'] =~ %r{^\/assets} }
        end

        it 'does not trace requests in which the callable returns true' do
          get '/assets'

          assets_span = finished_spans.find { |s| s.attributes['http.target'] == '/assets' }
          _(assets_span).must_be_nil

          root_span = finished_spans.find { |s| s.attributes['http.target'] == '/' }
          _(root_span).wont_be_nil
        end
      end

      describe 'when nil is passed in' do
        let(:config) { { untraced_requests: nil } }

        it 'traces everything' do
          get '/assets'

          asset_span = finished_spans.find { |s| s.attributes['http.target'] == '/assets' }
          _(asset_span).wont_be_nil

          root_span = finished_spans.find { |s| s.attributes['http.target'] == '/' }
          _(root_span).wont_be_nil
        end
      end
    end

    describe 'config[:allowed_request_headers]' do
      let(:headers) do
        Hash(
          'CONTENT_LENGTH' => '123',
          'CONTENT_TYPE' => 'application/json',
          'HTTP_FOO_BAR' => 'http foo bar value'
        )
      end

      it 'defaults to nil' do
        _(first_span.attributes['http.request.header.foo_bar']).must_be_nil
      end

      describe 'when configured' do
        let(:allowed_request_headers) do
          ['foo_BAR']
        end

        it 'returns attribute' do
          _(first_span.attributes['http.request.header.foo_bar']).must_equal 'http foo bar value'
        end
      end

      describe 'when content-type' do
        let(:allowed_request_headers) { ['CONTENT_TYPE'] }

        it 'returns attribute' do
          _(first_span.attributes['http.request.header.content_type']).must_equal 'application/json'
        end
      end

      describe 'when content-length' do
        let(:allowed_request_headers) { ['CONTENT_LENGTH'] }

        it 'returns attribute' do
          _(first_span.attributes['http.request.header.content_length']).must_equal '123'
        end
      end
    end

    describe 'config[:allowed_response_headers]' do
      let(:service) do
        ->(_env) { [200, { 'Foo-Bar' => 'foo bar response header' }, ['OK']] }
      end

      it 'defaults to nil' do
        _(first_span.attributes['http.response.header.foo_bar']).must_be_nil
      end

      describe 'when configured' do
        let(:allowed_response_headers) { ['Foo-Bar'] }

        it 'returns attribute' do
          _(first_span.attributes['http.response.header.foo_bar']).must_equal 'foo bar response header'
        end

        describe 'case-sensitively' do
          let(:allowed_response_headers) { ['fOO-bAR'] }

          it 'returns attribute' do
            _(first_span.attributes['http.response.header.foo_bar']).must_equal 'foo bar response header'
          end
        end
      end
    end

    describe 'record_frontend_span' do
      let(:request_span) { exporter.finished_spans.first }

      describe 'default' do
        it 'does not record span' do
          _(exporter.finished_spans.size).must_equal 1
        end

        it 'does not parent the request_span' do
          _(request_span.parent_span_id).must_equal OpenTelemetry::Trace::INVALID_SPAN_ID
        end
      end

      describe 'when recordable' do
        let(:record_frontend_span) { true }
        let(:headers) { Hash('HTTP_X_REQUEST_START' => Time.now.to_i) }
        let(:frontend_span) { exporter.finished_spans[1] }
        let(:request_span) { exporter.finished_spans[0] }

        it 'records span' do
          _(exporter.finished_spans.size).must_equal 2
          _(frontend_span.name).must_equal 'http_server.proxy'
          _(frontend_span.attributes['service']).must_be_nil
        end

        it 'changes request_span kind' do
          _(request_span.kind).must_equal :internal
        end

        it 'frontend_span parents request_span' do
          _(request_span.parent_span_id).must_equal frontend_span.span_id
        end
      end
    end

    describe '#called with 400 level http status code' do
      let(:service) do
        ->(_env) { [404, { 'Foo-Bar' => 'foo bar response header' }, ['Not Found']] }
      end

      it 'leaves status code unset' do
        _(first_span.attributes['http.status_code']).must_equal 404
        _(first_span.kind).must_equal :server
        _(first_span.status.code).must_equal OpenTelemetry::Trace::Status::UNSET
      end
    end
  end

  describe 'url quantization' do
    describe 'when using standard Rack environment variables' do
      describe 'without quantization' do
        it 'span.name defaults to low cardinality name HTTP method' do
          get '/really_long_url'

          _(first_span.name).must_equal 'HTTP GET'
          _(first_span.attributes['http.target']).must_equal '/really_long_url'
        end
      end

      describe 'with simple quantization' do
        let(:quantization_example) do
          ->(url, _env) { url.to_s }
        end

        let(:url_quantization) { quantization_example }

        it 'sets the span.name to the full path' do
          get '/really_long_url'

          _(first_span.name).must_equal '/really_long_url'
          _(first_span.attributes['http.target']).must_equal '/really_long_url'
        end
      end

      describe 'with quantization' do
        let(:quantization_example) do
          # demonstrate simple shortening of URL:
          ->(url, _env) { url.to_s[0..5] }
        end
        let(:url_quantization) { quantization_example }

        it 'mutates url according to url_quantization' do
          get '/really_long_url'

          _(first_span.name).must_equal '/reall'
        end
      end
    end

    describe 'when using Action Dispatch custom environment variables' do
      describe 'without quantization' do
        it 'span.name defaults to low cardinality name HTTP method' do
          get '/really_long_url', {}, { 'REQUEST_URI' => '/action-dispatch-uri' }

          _(first_span.name).must_equal 'HTTP GET'
          _(first_span.attributes['http.target']).must_equal '/really_long_url'
        end
      end

      describe 'with simple quantization' do
        let(:quantization_example) do
          ->(url, _env) { url.to_s }
        end

        let(:url_quantization) { quantization_example }

        it 'sets the span.name to the full path' do
          get '/really_long_url', {}, { 'REQUEST_URI' => '/action-dispatch-uri' }

          _(first_span.name).must_equal '/action-dispatch-uri'
          _(first_span.attributes['http.target']).must_equal '/really_long_url'
        end
      end

      describe 'with quantization' do
        let(:quantization_example) do
          # demonstrate simple shortening of URL:
          ->(url, _env) { url.to_s[0..5] }
        end
        let(:url_quantization) { quantization_example }

        it 'mutates url according to url_quantization' do
          get '/really_long_url', {}, { 'REQUEST_URI' => '/action-dispatch-uri' }

          _(first_span.name).must_equal '/actio'
        end
      end
    end
  end

  describe 'response_propagators' do
    describe 'with default options' do
      it 'does not inject the traceresponse header' do
        get '/ping'
        _(last_response.headers).wont_include('traceresponse')
      end
    end

    describe 'with ResponseTextMapPropagator' do
      let(:response_propagators) { [OpenTelemetry::Trace::Propagation::TraceContext::ResponseTextMapPropagator.new] }

      it 'injects the traceresponse header' do
        get '/ping'
        _(last_response.headers).must_include('traceresponse')
      end
    end

    describe 'propagator throws' do
      class EventMockPropagator < OpenTelemetry::Trace::Propagation::TraceContext::ResponseTextMapPropagator
        def inject(carrier)
          raise 'Injection failed'
        end
      end

      let(:response_propagators) { [EventMockPropagator.new] }

      it 'records errors' do
        expect(OpenTelemetry).to receive(:handle_error).with(exception: instance_of(RuntimeError), message: /Unable/)

        get '/ping'
      end
    end
  end

  describe '#call with error' do
    EventHandlerError = Class.new(StandardError)

    let(:service) do
      ->(_env) { raise EventHandlerError }
    end

    it 'records error in span and then re-raises' do
      assert_raises EventHandlerError do
        get '/'
      end

      _(first_span.status.code).must_equal OpenTelemetry::Trace::Status::ERROR
    end
  end
end
