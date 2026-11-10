# Test-only DynamoDB bootstrap.
#
# The suite runs against DynamoDB Local on a random port, with a table named
# after the current process so parallel test runs can't collide. Nothing here
# can reach AWS: the endpoint is always an explicit localhost address.
require "socket"

module DynamoTestSupport
  module_function

  def port
    @port ||= begin
      server = TCPServer.new("127.0.0.1", 0)
      chosen = server.addr[1]
      server.close
      chosen
    end
  end

  def endpoint = "http://127.0.0.1:#{port}"

  def start!
    return if @started

    jar = Rails.root.join("vendor/dynamodb-local/DynamoDBLocal.jar")
    unless jar.exist?
      abort "DynamoDB Local missing. Run bin/ddb-download first."
    end

    java = JavaLocator.path
    db_path = Rails.root.join("db/dynamodb-local-test-#{Process.pid}")
    FileUtils.mkdir_p(db_path)

    @pid = Process.spawn(
      java,
      "-Djava.library.path=./DynamoDBLocal_lib",
      "-jar", "DynamoDBLocal.jar",
      "-sharedDb",
      "-dbPath", db_path.to_s,
      "-port", port.to_s,
      chdir: Rails.root.join("vendor/dynamodb-local").to_s,
      out: File::NULL,
      err: File::NULL
    )

    wait_for_port!
    @started = true
    at_exit { stop! }
  end

  def wait_for_port!(timeout: 30)
    deadline = Time.now + timeout
    loop do
      begin
        socket = TCPSocket.new("127.0.0.1", port)
        socket.close
        return true
      rescue Errno::ECONNREFUSED
        raise "DynamoDB Local did not start within #{timeout}s" if Time.now > deadline

        sleep 0.2
      end
    end
  end

  def stop!
    return unless @pid

    Process.kill("TERM", @pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @pid = nil
    @started = false
  end
end

RSpec.configure do |config|
  config.before(:suite) do
    DynamoTestSupport.start!
    ENV["AWS_ENDPOINT_URL"] = DynamoTestSupport.endpoint
    Aws.config.update(endpoint: DynamoTestSupport.endpoint)
    Bassinet::Dynamo::Bootstrap.ensure_table!
  end

  # Each example starts from an empty table rather than deleting items one by
  # one: rebuilding is fast under -sharedDb and can't leave residue behind.
  config.before(:each) do
    Bassinet::Dynamo::Bootstrap.reset!
  end
end
