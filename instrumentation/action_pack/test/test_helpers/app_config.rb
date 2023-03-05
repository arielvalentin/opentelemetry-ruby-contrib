# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

class Application < Rails::Application; end
require 'action_controller/railtie'
require_relative 'middlewares'
require_relative 'controllers'
require_relative 'routes'

module AppConfig
  extend self

  def initialize_app(use_exceptions_app: false, remove_rack_tracer_middleware: false, use_rack_events: true)
    new_app = Application.new
    new_app.config.secret_key_base = 'secret_key_base'

    # Ensure we don't see this Rails warning when testing
    new_app.config.eager_load = false

    # Prevent tests from creating log/*.log
    use_stderr = ENV.fetch('RAILS_LOG_STDERR', 'false') == 'true'
    io_stream = use_stderr ? $stderr : File::NULL
    level = ENV.fetch('OTEL_LOG_LEVEL', 'fatal').to_sym
    new_app.config.logger = Logger.new(io_stream, level: level)
    new_app.config.log_level = level

    new_app.config.filter_parameters = [:param_to_be_filtered]

    case Rails.version
    when /^6\.0/
      apply_rails_6_0_configs(new_app)
    when /^6\.1/
      apply_rails_6_1_configs(new_app)
    when /^7\./
      apply_rails_7_configs(new_app)
    end

    remove_rack_middleware(new_app) if remove_rack_tracer_middleware
    add_exceptions_app(new_app) if use_exceptions_app
    add_middlewares(new_app)

    OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_INSTRUMENTATION_RACK_CONFIG_OPTS' => "use_rack_events=#{use_rack_events}") do
      new_app.initialize!
    end
    draw_routes(new_app)

    new_app
  end

  private

  def remove_rack_middleware(application)
    application.middleware.delete(
      ::OpenTelemetry::Instrumentation::Rack::Middlewares::TracerMiddleware
    ) if defined?(::OpenTelemetry::Instrumentation::Rack::Middlewares::TracerMiddleware)
    application.middleware.delete(
      ::Rack::Events
    )
  end

  def add_exceptions_app(application)
    application.config.exceptions_app = lambda do |env|
      ExceptionsController.action(:show).call(env)
    end
  end

  def add_middlewares(application)
    application.middleware.insert_after(
      ActionDispatch::DebugExceptions,
      ExceptionRaisingMiddleware
    )

    application.middleware.insert_after(
      ActionDispatch::DebugExceptions,
      RedirectMiddleware
    )
  end

  def apply_rails_6_0_configs(application)
    # Required in Rails 6
    application.config.hosts << 'example.org'
    # Creates a lot of deprecation warnings on subsequent app initializations if not explicitly set.
    application.config.action_view.finalize_compiled_template_methods = ActionView::Railtie::NULL_OPTION
  end

  def apply_rails_6_1_configs(application)
    # Required in Rails 6
    application.config.hosts << 'example.org'
  end

  def apply_rails_7_configs(application)
    # Required in Rails 7
    application.config.hosts << 'example.org'

    # Unfreeze values which may have been frozen on previous initializations.
    ActiveSupport::Dependencies.autoload_paths =
      ActiveSupport::Dependencies.autoload_paths.dup
    ActiveSupport::Dependencies.autoload_once_paths =
      ActiveSupport::Dependencies.autoload_once_paths.dup
  end
end
