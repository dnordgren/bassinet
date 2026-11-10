module Bassinet
  module Dynamo
    # Key construction and parsing. Every key the app uses is built here so a
    # typo can't silently create a second, invisible partition.
    module Keys
      # 15 digits covers year ~33658. Lexicographic order == numeric order,
      # permanently, which is what makes the sort key a usable time index.
      EPOCH_DIGITS = 15

      module_function

      # --- households -------------------------------------------------------
      def household_pk(household_id) = "HOUSEHOLD##{household_id}"
      def household_meta_sk = "META"
      def member_sk(user_id) = "MEMBER##{user_id}"
      def invite_sk(token_hash) = "INVITE##{token_hash}"

      # --- users ------------------------------------------------------------
      def user_pk(user_id) = "USER##{user_id}"
      def user_profile_sk = "PROFILE"
      def user_session_sk(session_id) = "SESSION##{session_id}"
      def email_pk(email) = "EMAIL##{email.to_s.downcase.strip}"
      def email_index_sk = "USER"

      # --- children ---------------------------------------------------------
      def child_pk(child_id) = "CHILD##{child_id}"
      def child_meta_sk = "META"
      def child_list_gsi2pk(household_id) = "HOUSEHOLD##{household_id}#CHILD"

      # Live children must sort before archived ones in *every* case, so the
      # archive marker leads the sort key. Putting it last (after the child id)
      # would let the id decide the order and scatter archived kids through the
      # list. Live is "0" — a prefix of any 15-digit padded epoch, so it always
      # compares lower.
      def child_list_gsi2sk(child_id, archived_at = nil)
        archived_flag = archived_at.nil? || archived_at.to_i.zero? ? "0" : padded_epoch(archived_at)
        "CHILD##{archived_flag}##{child_id}"
      end

      # --- events -----------------------------------------------------------
      def event_sk(occurred_at_ms, event_id)
        "EVENT##{padded_epoch(occurred_at_ms)}##{event_id}"
      end

      def padded_epoch(ms)
        ms.to_i.to_s.rjust(EPOCH_DIGITS, "0")
      end

      # Returns [occurred_at_ms, event_id] or nil for a non-event SK.
      def parse_event_sk(sk)
        return nil unless sk&.start_with?("EVENT#")

        _, epoch, event_id = sk.split("#", 3)
        return nil if epoch.nil? || event_id.nil?

        [epoch.to_i, event_id]
      end

      # Sort-key bounds for "everything between these two instants". Using
      # padded epoch without an event id gives an open range at each end.
      def event_sk_lower(ms) = event_sk(ms, "")
      def event_sk_upper(ms) = event_sk(ms, "\u{FFFF}")
    end
  end
end
