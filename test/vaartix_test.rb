# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/vaartix"

class FakeHTTP
  attr_reader :calls

  def initialize(status, body)
    @status = status
    @body = body
    @calls = []
  end

  def call(method, url, headers, body)
    @calls << { method: method, url: url, headers: headers, body: body && JSON.parse(body) }
    [@status, @body]
  end

  def last = @calls.last
end

class ClientTest < Minitest::Test
  def client(status, body)
    @http = FakeHTTP.new(status, body)
    Vaartix::Client.new("vx_test", base_url: "https://api.example/", http: @http)
  end

  def test_needs_a_key
    ENV.delete("VAARTIX_API_KEY")
    assert_raises(ArgumentError) { Vaartix::Client.new }
  end

  def test_send_email
    c = client(200, '{"id":"em_123"}')
    res = c.emails.send({ from: "Acme <orders@acme.in>", to: "priya@example.com", subject: "Hi", html: "<p>Hi</p>",
                          reply_to: "help@acme.in", text: nil, tracking: { opens: true } }, idempotency_key: "order-1")
    assert_equal "em_123", res["id"]
    call = @http.last
    assert_equal :post, call[:method]
    assert_equal "https://api.example/emails", call[:url]
    assert_equal "Bearer vx_test", call[:headers]["Authorization"]
    assert_equal "vaartix-ruby/#{Vaartix::VERSION}", call[:headers]["User-Agent"]
    assert_equal "order-1", call[:headers]["Idempotency-Key"]
    assert_equal "help@acme.in", call[:body]["replyTo"]
    refute call[:body].key?("text")
    assert_equal({ "opens" => true }, call[:body]["tracking"])
  end

  def test_errors
    c = client(422, '{"error":{"type":"validation_error","message":"to: not a valid email address."}}')
    e = assert_raises(Vaartix::Error) { c.emails.send(from: "a@acme.in", to: "x", subject: "s", text: "t") }
    assert_equal "validation_error", e.type
    assert_equal 422, e.status_code
    c2 = client(500, "oops")
    e2 = assert_raises(Vaartix::Error) { c2.emails.get("em_1") }
    assert_equal "api_error", e2.type
    broken = Vaartix::Client.new("vx_test", http: ->(*) { raise SocketError, "no route" })
    e3 = assert_raises(Vaartix::Error) { broken.emails.get("em_1") }
    assert_equal "network_error", e3.type
    assert_nil e3.status_code
  end

  def test_read_list_cancel
    c = client(200, '{"id":"em_1","status":"delivered"}')
    assert_equal "delivered", c.emails.get("em_1/x")["status"]
    assert_equal "https://api.example/emails/em_1%2Fx", @http.last[:url]
    c.emails.list(limit: 5, before: "em_9")
    assert_equal "https://api.example/emails?limit=5&before=em_9", @http.last[:url]
    c.emails.cancel("em_3")
    assert_equal "https://api.example/emails/em_3/cancel", @http.last[:url]
  end

  def test_batch_and_domains
    c = client(200, '{"data":[{"id":"em_a"},{"id":"em_b"}]}')
    assert_equal 2, c.batch.send([{ from: "a@acme.in", to: "x@y.in", subject: "1", text: "1" }]).size
    assert_kind_of Array, @http.last[:body]
    c2 = client(200, '{"id":"dom_1","openTracking":true}')
    c2.domains.update("dom_1", open_tracking: true)
    assert_equal :patch, @http.last[:method]
    assert_equal({ "openTracking" => true }, @http.last[:body])
  end

  def test_webhooks
    c = client(200, '{"id":"wh_1","secret":"whsec_x","data":[]}')
    assert_equal "whsec_x", c.webhooks.create(url: "https://acme.in/h", events: [Vaartix::Events::DELIVERED])["secret"]
    c.webhooks.update("wh_1", status: "disabled")
    assert_equal({ "status" => "disabled" }, @http.last[:body])
    c.webhooks.rotate_secret("wh_1")
    assert_equal "https://api.example/webhooks/wh_1/rotate-secret", @http.last[:url]
    c.webhooks.deliveries("wh_1", limit: 10)
    assert_equal "https://api.example/webhooks/wh_1/deliveries?limit=10", @http.last[:url]
    c.webhooks.retry_delivery("wh_1", "whd_2")
    assert_equal "https://api.example/webhooks/wh_1/deliveries/whd_2/retry", @http.last[:url]
    c2 = client(204, "")
    assert_nil c2.webhooks.remove("wh_1")
    assert_equal :delete, @http.last[:method]
  end
end

class WebhookTest < Minitest::Test
  # Test-only secret: the worked example from the Standard Webhooks specification.
  PREFIX = "whsec_"
  SPEC_SECRET = "#{PREFIX}MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
  SPEC_BODY = '{"test": 2432232314}'
  NOW = 1_614_265_330

  def headers
    { "webhook-id" => "msg_p5jXN8AQM9LWM0D4loKWxJek", "webhook-timestamp" => "1614265330",
      "webhook-signature" => "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=" }
  end

  def test_reference_example_and_rails_style_headers
    assert_equal({ "test" => 2_432_232_314 }, Vaartix.verify_webhook(SPEC_BODY, headers, SPEC_SECRET, now: NOW))
    rails = headers.to_h { |k, v| ["HTTP_#{k.upcase.tr("-", "_")}", v] }
    assert Vaartix.verify_webhook(SPEC_BODY, rails, SPEC_SECRET, now: NOW)
    multi = headers.merge("webhook-signature" => "v1,bm90LXRoaXM= #{headers["webhook-signature"]}")
    assert Vaartix.verify_webhook(SPEC_BODY, multi, SPEC_SECRET, now: NOW)
  end

  def test_rejections
    [
      -> { Vaartix.verify_webhook('{"test": 1}', headers, SPEC_SECRET, now: NOW) },
      -> { Vaartix.verify_webhook(SPEC_BODY, headers, "#{PREFIX}c2VjcmV0", now: NOW) },
      -> { Vaartix.verify_webhook(SPEC_BODY, headers, SPEC_SECRET, now: NOW + 600) },
      -> { Vaartix.verify_webhook(SPEC_BODY, {}, SPEC_SECRET, now: NOW) },
      -> { Vaartix.verify_webhook(SPEC_BODY, headers, "nope", now: NOW) }
    ].each { |f| assert_raises(Vaartix::WebhookVerificationError) { f.call } }
  end

  def test_delayed_payload
    body = '{"type":"email.delivery_delayed","data":{"recipient":"a@yahoo.com","details":{"delayType":"TransientCommunicationFailure","diagnosticCode":"421 4.7.0 [TSS04]","statusCode":"4.7.0"}}}'
    secret = PREFIX + Base64.strict_encode64("0123456789abcdef0123456789abcdef")
    sig = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", Base64.strict_decode64(secret.delete_prefix(PREFIX)), "whd_1.#{NOW}.#{body}"))
    event = Vaartix.verify_webhook(body, { "webhook-id" => "whd_1", "webhook-timestamp" => NOW.to_s, "webhook-signature" => "v1,#{sig}" }, secret, now: NOW)
    assert_equal Vaartix::Events::DELIVERY_DELAYED, event["type"]
    assert_equal "421 4.7.0 [TSS04]", event["data"]["details"]["diagnosticCode"]
  end
end
