# AWS SDK configuration.
#
# Key rule: this app has TWO independent concerns that both need AWS config —
#   * domain data  -> DynamoDB (this file)
#   * nothing else -> there is no S3, no SQS, no SES in v1
#
# Endpoint override exists so development and test can point at DynamoDB Local
# without touching credentials. In production AWS_ENDPOINT_URL is unset and the
# SDK resolves the real regional endpoint.
Rails.application.config.to_prepare do
  # Development and test default to a local DynamoDB instance so a fresh clone
  # works with `bin/ddb-start` and nothing else. Set AWS_ENDPOINT_URL to point
  # somewhere else (including a real AWS table, with blank endpoint handling
  # below). Production always uses the regional endpoint.
  endpoint = ENV["AWS_ENDPOINT_URL"].presence
  endpoint ||= "http://127.0.0.1:8000" unless Rails.env.production?

  Aws.config.update(
    region: ENV.fetch("AWS_REGION", "us-east-1"),
    endpoint: endpoint,
    # Our Marshal layer owns attribute conversion in both directions. The
    # SDK's simple_attributes plugin would do it too, and the two implementations
    # fight: tagged values get double-wrapped into {"M" => {"S" => ...}} and the
    # server rejects them. Turn it off and keep one conversion path.
    simple_attributes: false,
    # DynamoDB Local accepts any credentials, but the SDK refuses to sign
    # without them. Real deploys use the instance role or Kamal secrets.
    credentials: if endpoint
      Aws::Credentials.new("local", "local")
    else
      Aws::Credentials.new(
        ENV["AWS_ACCESS_KEY_ID"],
        ENV["AWS_SECRET_ACCESS_KEY"]
      )
    end,
    # Keep retries shallow: a stalled Dynamo call must not hang a web request.
    retry_limit: 3,
    http_open_timeout: 2,
    http_read_timeout: 5
  )
end
