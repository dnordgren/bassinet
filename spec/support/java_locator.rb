# Resolves a `java` binary without assuming the shell has mise activated.
#
# Rails is started by whatever shell happens to run the suite, and `mise` may
# not have exported JAVA_HOME. Rather than make every caller remember to
# `mise exec`, look in the obvious places and fail with a useful message.
module JavaLocator
  module_function

  def path
    @path ||= find
  end

  def find
    candidates = []
    candidates << File.join(ENV["JAVA_HOME"], "bin", "java") if ENV["JAVA_HOME"].present?
    candidates << `mise which java 2>/dev/null`.strip.presence

    # mise keeps installs under a predictable path; check the newest stable one.
    mise_root = File.join(Dir.home, ".local/share/mise/installs/java")
    if Dir.exist?(mise_root)
      Dir.children(mise_root).sort.reverse_each do |version|
        candidates << File.join(mise_root, version, "bin", "java")
      end
    end

    candidates << "/usr/bin/java"
    candidates << "/usr/local/bin/java"

    found = candidates.compact.find { |c| File.executable?(c) }
    return found if found

    abort <<~MSG
      No `java` binary found. DynamoDB Local needs a JRE.

        mise use java
        bin/ddb-download

      Or set JAVA_HOME to a JDK/JRE installation.
    MSG
  end
end
