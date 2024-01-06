# frozen_string_literal: true

require 'faraday'
require 'json'

require_relative '../ports/dsl/ollama-ai/errors'

module Ollama
  module Controllers
    class Client
      DEFAULT_ADDRESS = 'http://localhost:11434'

      ALLOWED_REQUEST_OPTIONS = %i[timeout open_timeout read_timeout write_timeout].freeze

      def initialize(config)
        @server_sent_events = config.dig(:options, :server_sent_events)

        @address = if config[:credentials][:address].nil? || config[:credentials][:address].to_s.strip.empty?
                     "#{DEFAULT_ADDRESS}/"
                   else
                     "#{config[:credentials][:address].to_s.sub(%r{/$}, '')}/"
                   end

        @request_options = config.dig(:options, :connection, :request)

        @request_options = if @request_options.is_a?(Hash)
                             @request_options.select do |key, _|
                               ALLOWED_REQUEST_OPTIONS.include?(key)
                             end
                           else
                             {}
                           end
      end

      def generate(payload, server_sent_events: nil, &callback)
        request('api/generate', payload, server_sent_events:, &callback)
      end

      def chat(payload, server_sent_events: nil, &callback)
        request('api/chat', payload, server_sent_events:, &callback)
      end

      def create(payload, server_sent_events: nil, &callback)
        request('api/create', payload, server_sent_events:, &callback)
      end

      def tags(server_sent_events: nil, &callback)
        request('api/tags', nil, server_sent_events:, request_method: 'GET', &callback)
      end

      def show(payload, server_sent_events: nil, &callback)
        request('api/show', payload, server_sent_events:, &callback)
      end

      def copy(payload, server_sent_events: nil, &callback)
        request('api/copy', payload, server_sent_events:, &callback)
        true
      end

      def delete(payload, server_sent_events: nil, &callback)
        request('api/delete', payload, server_sent_events:, request_method: 'DELETE', &callback)
        true
      end

      def pull(payload, server_sent_events: nil, &callback)
        request('api/pull', payload, server_sent_events:, &callback)
      end

      def push(payload, server_sent_events: nil, &callback)
        request('api/push', payload, server_sent_events:, &callback)
      end

      def embeddings(payload, server_sent_events: nil, &callback)
        request('api/embeddings', payload, server_sent_events:, &callback)
      end

      def request(path, payload = nil, server_sent_events: nil, request_method: 'POST', &callback)
        server_sent_events_enabled = server_sent_events.nil? ? @server_sent_events : server_sent_events
        url = "#{@address}#{path}"

        if !callback.nil? && !server_sent_events_enabled
          raise BlockWithoutServerSentEventsError,
                'You are trying to use a block without Server Sent Events (SSE) enabled.'
        end

        results = []

        method_to_call = request_method.to_s.strip.downcase.to_sym

        partial_json = ''

        response = Faraday.new(request: @request_options) do |faraday|
          faraday.response :raise_error
        end.send(method_to_call) do |request|
          request.url url
          request.headers['Content-Type'] = 'application/json'

          request.body = payload.to_json unless payload.nil?

          if server_sent_events_enabled
            request.options.on_data = proc do |chunk, bytes, env|
              if env && env.status != 200
                raise_error = Faraday::Response::RaiseError.new
                raise_error.on_complete(env.merge(body: chunk))
              end

              partial_json += chunk

              parsed_json = safe_parse_json(partial_json)

              if parsed_json
                result = { event: parsed_json, raw: { chunk:, bytes:, env: } }

                callback.call(result[:event], result[:raw]) unless callback.nil?

                results << result

                partial_json = ''
              end
            end
          end
        end

        return safe_parse_jsonl(response.body) unless server_sent_events_enabled

        results.map { |result| result[:event] }
      rescue Faraday::Error => e
        raise RequestError.new(e.message, request: e, payload:)
      end

      def safe_parse_json(raw)
        raw.to_s.lstrip.start_with?('{', '[') ? JSON.parse(raw) : nil
      rescue JSON::ParserError
        nil
      end

      def safe_parse_jsonl(raw)
        raw.to_s.lstrip.start_with?('{', '[') ? raw.split("\n").map { |line| JSON.parse(line) } : raw
      rescue JSON::ParserError
        raw
      end
    end
  end
end