Rails.application.routes.draw do
  # Health check for load balancers and uptime monitors.
  get "up" => "rails/health#show", as: :rails_health_check

  # --- auth ---------------------------------------------------------------
  get  "sign-in",  to: "auth/sessions#new",  as: :sign_in
  delete "sign-out", to: "auth/sessions#destroy", as: :sign_out

  namespace :auth do
    get "start", to: "oauth#start", as: :start
    get "google/callback", to: "oauth#callback", as: :callback

    # iOS standalone handoff (docs/auth.md §2)
    post "handoff", to: "handoff#create", as: :handoff_create
    get  "handoff/poll/:id", to: "handoff#poll", as: :handoff_poll, constraints: { id: /[^\/]+/ }
    post "handoff/session", to: "handoff#session_create", as: :handoff_session
    get  "handoff/finished", to: "handoff#finished", as: :handoff_finished
    # Keep this last: it would otherwise shadow the literal routes above.
    get  "handoff/:code", to: "handoff#entry", as: :handoff_entry
  end

  root "home#index"
end
