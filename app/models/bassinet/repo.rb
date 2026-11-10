module Bassinet
  # Every repository is constructed with a household scope. A repository that
  # can read or write data belonging to another household is a bug, not a
  # footgun — so the household is a required argument at construction time and
  # there is no way to widen it afterwards.
  class Repo
    class ScopeError < StandardError; end

    attr_reader :household_id, :client

    def initialize(household_id:, client: nil)
      raise ScopeError, "household_id is required" if household_id.blank?

      @household_id = household_id
      @client = client || Dynamo::Client.new
    end

    private

    def now_ms = Dynamo::Marshal.now_ms

    # Guard for every write that names a child: the child must belong to this
    # repository's household. Callers cannot skip it, because every write path
    # goes through this.
    def assert_child_in_scope!(child_id)
      child = client.get(pk: Dynamo::Keys.child_pk(child_id),
                         sk: Dynamo::Keys.child_meta_sk)
      raise Dynamo::Client::NotFound, "child #{child_id} not found" if child.nil?

      unless child["household_id"] == household_id
        # Deliberately indistinguishable from NotFound at the HTTP layer; the
        # distinct exception exists so our own specs can prove scoping works.
        raise ScopeError, "child #{child_id} is not in household #{household_id}"
      end

      child
    end
  end
end
