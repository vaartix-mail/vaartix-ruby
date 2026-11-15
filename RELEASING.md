# Releasing

Published to RubyGems as `vaartix` by GitHub Actions with trusted publishing: no API key exists.

## One-time setup

1. Create a RubyGems account (as Vaartix) with MFA on.
2. rubygems.org → your profile → **Trusted publishers** → **Create** a *pending* trusted publisher:
   gem name `vaartix`, repository `vaartix-mail/vaartix-ruby`, workflow `publish.yml`, environment `rubygems`.
3. GitHub → Settings → Environments → `rubygems`: required reviewer (you), deployment tags `v*` only.

## Each release

1. Update `lib/vaartix/version.rb` and move the "Unreleased" notes in `CHANGELOG.md`. Merge to `main`.
2. Create a GitHub release with the tag `v<version>` on `main`, then approve the publish run.
