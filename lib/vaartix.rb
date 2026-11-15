# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "openssl"
require "base64"
require_relative "vaartix/version"

# The official Ruby client for Vaartix, the transactional email API built in India.
#
#   vaartix = Vaartix::Client.new # reads VAARTIX_API_KEY
#   vaartix.emails.send(from: "Acme <orders@acme.in>", to: "priya@example.com",
#                       subject: "Your order is confirmed", html: "<p>Thanks!</p>")
#   # => {"id"=>"em_..."}
module Vaartix
  DEFAULT_BASE_URL = "https://api.vaartix.com"

  # The API answered with an error, or the request could not be made.
  class Error < StandardError
    # The API's error type, e.g. "validation_error", or "network_error".
    attr_reader :type
    # The HTTP status, or nil when no response was received.
    attr_reader :status_code

    def initialize(type, message, status_code = nil)
      super(message)
      @type = type
      @status_code = status_code
    end
  end

  # A webhook request's signature, timestamp or body is not valid.
  class WebhookVerificationError < StandardError; end

  # snake_case keys you pass become the API's camelCase (reply_to -> replyTo).
  KEY_NAMES = {
    reply_to: :replyTo, scheduled_at: :scheduledAt, content_type: :contentType, content_id: :contentId,
    open_tracking: :openTracking, click_tracking: :clickTracking
  }.freeze

  def self.to_api(value)
    case value
    when Hash then value.each_with_object({}) { |(k, v), h| h[KEY_NAMES.fetch(k.to_sym, k)] = to_api(v) unless v.nil? }
    when Array then value.map { |v| to_api(v) }
    else value
    end
  end

  # Thread-safe client. Create one and reuse it.
  class Client
    attr_reader :emails, :batch, :domains, :webhooks

    # http: optional callable(method, url, headers, body) -> [status, body], for tests or custom transports.
    def initialize(api_key = nil, base_url: DEFAULT_BASE_URL, timeout: 30, http: nil)
      @api_key = api_key || ENV.fetch("VAARTIX_API_KEY", nil)
      if @api_key.nil? || @api_key.empty?
        raise ArgumentError, "Missing API key. Pass it to Vaartix::Client.new(\"vx_...\") or set VAARTIX_API_KEY."
      end

      @base_url = base_url.sub(%r{/+\z}, "")
      @timeout = timeout
      @http = http || method(:net_http)
      @emails = Emails.new(self)
      @batch = Batch.new(self)
      @domains = Domains.new(self)
      @webhooks = Webhooks.new(self)
    end

    # @api private
    def request(method, path, body = nil, idempotency_key: nil)
      headers = {
        "Authorization" => "Bearer #{@api_key}",
        "User-Agent" => "vaartix-ruby/#{VERSION}",
        "Accept" => "application/json"
      }
      headers["Content-Type"] = "application/json" unless body.nil?
      headers["Idempotency-Key"] = idempotency_key if idempotency_key
      payload = body.nil? ? nil : JSON.generate(Vaartix.to_api(body))
      begin
        status, raw = @http.call(method, "#{@base_url}#{path}", headers, payload)
      rescue StandardError => e
        raise Error.new("network_error", e.message)
      end
      parsed = begin
        raw.nil? || raw.empty? ? nil : JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end
      return parsed if status.between?(200, 299)

      err = parsed.is_a?(Hash) && parsed["error"].is_a?(Hash) ? parsed["error"] : {}
      raise Error.new(err["type"] || "api_error", err["message"] || "Request failed with status #{status}", status)
    end

    def self.escape(id) = URI.encode_www_form_component(id.to_s).gsub("+", "%20")

    private

    def net_http(method, url, headers, body)
      uri = URI(url)
      klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch, delete: Net::HTTP::Delete }.fetch(method)
      req = klass.new(uri)
      headers.each { |k, v| req[k] = v }
      req.body = body if body
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @timeout, read_timeout: @timeout) do |h|
        h.request(req)
      end
      [res.code.to_i, res.body]
    end
  end

  # Send and read emails.
  class Emails
    def initialize(client) = @client = client

    # Send one email. Keys can be snake_case (reply_to, scheduled_at) or camelCase.
    # tracking: { opens: true, clicks: false } overrides the domain's defaults.
    # Pass a hash, or the fields as keywords: emails.send(from: ..., to: ..., subject: ..., html: ...).
    def send(email = nil, idempotency_key: nil, **fields)
      @client.request(:post, "/emails", email || fields, idempotency_key: idempotency_key)
    end

    # One email with its events. Needs a full-access key.
    def get(id) = @client.request(:get, "/emails/#{Client.escape(id)}")

    # Recent emails, newest first. Needs a full-access key.
    def list(limit: nil, before: nil)
      query = URI.encode_www_form({ limit: limit, before: before }.compact)
      @client.request(:get, "/emails#{query.empty? ? "" : "?#{query}"}")
    end

    # Cancel a scheduled email before it is sent. Needs a full-access key.
    def cancel(id) = @client.request(:post, "/emails/#{Client.escape(id)}/cancel")
  end

  # Send many emails in one request.
  class Batch
    def initialize(client) = @client = client

    # Up to 100 emails (no attachments or scheduling). All or nothing. Returns the list of {"id"=>...}.
    def send(emails) = @client.request(:post, "/emails/batch", emails)["data"]
  end

  # Sending domains. Changes need a full-access key from an owner or admin.
  class Domains
    def initialize(client) = @client = client

    # Change a domain's default open and click tracking. Keys left out keep their value.
    def update(id, open_tracking: nil, click_tracking: nil)
      @client.request(:patch, "/domains/#{Client.escape(id)}", { open_tracking: open_tracking, click_tracking: click_tracking })
    end
  end

  # Webhook endpoints. Needs a full-access key.
  class Webhooks
    def initialize(client) = @client = client

    # Create an endpoint. The response includes the signing secret, shown only this once.
    def create(url:, events:) = @client.request(:post, "/webhooks", { url: url, events: events })
    def list = @client.request(:get, "/webhooks")["data"]
    def get(id) = @client.request(:get, "/webhooks/#{Client.escape(id)}")

    # Change the URL or events, or turn the endpoint off (status: "disabled") and on.
    def update(id, url: nil, events: nil, status: nil)
      @client.request(:patch, "/webhooks/#{Client.escape(id)}", { url: url, events: events, status: status })
    end

    def remove(id) = @client.request(:delete, "/webhooks/#{Client.escape(id)}")

    # Replace the signing secret. The old one stops working immediately.
    def rotate_secret(id) = @client.request(:post, "/webhooks/#{Client.escape(id)}/rotate-secret")

    # Recent deliveries, newest first.
    def deliveries(id, limit: nil)
      @client.request(:get, "/webhooks/#{Client.escape(id)}/deliveries#{limit ? "?limit=#{Integer(limit)}" : ""}")["data"]
    end

    # Send a delivery again, with the same webhook-id.
    def retry_delivery(id, delivery_id)
      @client.request(:post, "/webhooks/#{Client.escape(id)}/deliveries/#{Client.escape(delivery_id)}/retry")
    end
  end

  # Webhook event types.
  module Events
    SENT = "email.sent"
    DELIVERED = "email.delivered"
    DELIVERY_DELAYED = "email.delivery_delayed"
    BOUNCED = "email.bounced"
    COMPLAINED = "email.complained"
    REJECTED = "email.rejected"
    RENDERING_FAILURE = "email.rendering_failure"
    SUPPRESSED = "email.suppressed"
    OPENED = "email.opened"
    CLICKED = "email.clicked"
    ALL = [SENT, DELIVERED, DELIVERY_DELAYED, BOUNCED, COMPLAINED, REJECTED, RENDERING_FAILURE, SUPPRESSED, OPENED,
           CLICKED].freeze
  end

  # Check that a webhook request really came from Vaartix (Standard Webhooks) and return its parsed body.
  # payload must be the raw body (request.raw_post in Rails). headers: any case, e.g. request.headers.
  # Delays and bounces carry the receiving server's reply in data.details.diagnosticCode.
  def self.verify_webhook(payload, headers, secret, tolerance: 300, now: Time.now.to_i)
    get = ->(name) { headers[name] || headers.find { |k, _| k.to_s.downcase.tr("_", "-").sub(/\Ahttp-/, "") == name }&.last }
    id = get.("webhook-id")
    timestamp = get.("webhook-timestamp")
    signatures = get.("webhook-signature")
    raise WebhookVerificationError, "Missing webhook-id, webhook-timestamp or webhook-signature header." unless id && timestamp && signatures

    sent = Integer(timestamp, exception: false)
    raise WebhookVerificationError, "The webhook timestamp is too old or in the future." if sent.nil? || (now - sent).abs > tolerance
    raise WebhookVerificationError, "The secret should start with whsec_." unless secret.to_s.start_with?("whsec_")

    key = Base64.strict_decode64(secret.delete_prefix("whsec_"))
    expected = OpenSSL::HMAC.digest("SHA256", key, "#{id}.#{timestamp}.#{payload}")
    valid = signatures.split(" ").any? do |entry|
      version, signature = entry.split(",", 2)
      next false unless version == "v1" && signature

      given = Base64.decode64(signature)
      given.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(given, expected)
    end
    raise WebhookVerificationError, "The webhook signature does not match." unless valid

    JSON.parse(payload)
  rescue ArgumentError
    raise WebhookVerificationError, "The secret is not valid base64."
  rescue JSON::ParserError
    raise WebhookVerificationError, "The body is not valid JSON."
  end
end
