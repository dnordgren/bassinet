# Table and index names, in one place.
#
# The table name is environment-suffixed so a dev machine, the test suite and
# production never share a table. `bassinet-test-<pid>` keeps parallel specs
# isolated from each other.
module Bassinet
  module Dynamo
    module Tables
      ENVIRONMENTS = %w[production development test].freeze

      def self.current
        explicit = ENV["BASSINET_TABLE"].presence
        return explicit if explicit

        env = Rails.env
        raise "unknown RAILS_ENV: #{env}" unless ENVIRONMENTS.include?(env)

        env == "test" ? "bassinet-test-#{Process.pid}" : "bassinet-#{env}"
      end

      def self.prefix
        current
      end
    end
  end
end
