module Auth
  # Sign-in landing page and sign-out. Deliberately tiny: one button for Google,
  # and a clear explanation of the iOS standalone handoff when it applies.
  class SessionsController < ApplicationController
    def new
      return redirect_to(root_path) if signed_in?

      @google_configured = Bassinet::GoogleOAuth.configured?
      @pending_handoff = params[:handoff].presence
    end

    def destroy
      sign_out!
      redirect_to sign_in_path, notice: "Signed out."
    end
  end
end
