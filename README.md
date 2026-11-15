# Vaartix Ruby SDK

The official Ruby client for [Vaartix](https://vaartix.com), the transactional email API built in India.
Data stored in India (AWS Mumbai), pricing in ₹.

```sh
gem install vaartix
# or in your Gemfile
gem "vaartix"
```

Ruby 3.1 or newer. No dependencies outside the standard library.

## Send an email

```ruby
require "vaartix"

vaartix = Vaartix::Client.new # reads VAARTIX_API_KEY

email = vaartix.emails.send(
  from: "Acme <orders@acme.in>", # an address on a domain verified in Vaartix
  to: "priya@example.com",
  subject: "Your order is confirmed",
  html: "<p>Thanks for your order!</p>"
)
email["id"] # => "em_..."
```

Keys can be snake_case (`reply_to`, `scheduled_at`) or the API's camelCase. Responses are the API's JSON as
hashes. Testing? Send to `delivered@test.vaartix.com` (or `bounced@` / `complained@`); nothing real is sent.

## Errors

```ruby
begin
  vaartix.emails.send(...)
rescue Vaartix::Error => e
  e.type        # "validation_error", "rate_limit_exceeded", ... or "network_error"
  e.status_code # 422, 429, ... or nil when no response was received
end
```

## More sending options

```ruby
vaartix.emails.send(email, idempotency_key: "receipt-10482")  # safe retries for 24 hours
vaartix.emails.send(**email, scheduled_at: "2026-11-15T10:00:00+05:30")
vaartix.batch.send([email_a, email_b])                          # up to 100 in one request
vaartix.emails.send(**email, tracking: { opens: true, clicks: false })
```

Keep click tracking off for login codes, password resets and magic links.

## Read emails

Needs a full-access key.

```ruby
vaartix.emails.get("em_...")          # content, status and events
vaartix.emails.list(limit: 50)        # {"data"=>[...], "hasMore"=>true}
vaartix.emails.cancel("em_...")       # a scheduled email
```

## Webhooks

Check that a webhook request really came from Vaartix before you trust it. Use the **raw** body.

```ruby
# Rails
class VaartixWebhooksController < ActionController::API
  def create
    event = Vaartix.verify_webhook(request.raw_post, request.headers, ENV.fetch("VAARTIX_WEBHOOK_SECRET"))
    if event["type"] == Vaartix::Events::BOUNCED
      reply = event["data"]["details"]["diagnosticCode"] # the receiving server's reply
    end
    head :ok
  rescue Vaartix::WebhookVerificationError
    head :bad_request
  end
end
```

Signatures follow the [Standard Webhooks](https://www.standardwebhooks.com) spec. Manage endpoints with
`vaartix.webhooks.create`, `list`, `get`, `update`, `remove`, `rotate_secret`, `deliveries` and `retry_delivery`.

## Domains

```ruby
vaartix.domains.update(domain_id, open_tracking: true)
```

## Docs

- Docs: https://vaartix.com/docs
- API reference: https://vaartix.com/docs/api
- Status: https://status.vaartix.com

## Contributing and security

Issues and pull requests are welcome. Report security problems privately, see [SECURITY.md](SECURITY.md).

## License

MIT
