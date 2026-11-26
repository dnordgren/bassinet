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

  # --- children -----------------------------------------------------------
  resources :children, only: %i[new create]

  # --- events, scoped under a child ---------------------------------------
  # The event sort key is (occurred_at, event_id), so a member URL has to carry
  # both: `occurred_at` is part of the identity, not a display detail.
  scope "c/:child_id" do
    get "day/:date", to: "days#show", as: :child_day,
                     constraints: { date: /\d{4}-\d{2}-\d{2}/ }

    get  "events/new", to: "events#new", as: :new_child_event
    post "events", to: "events#create", as: :child_events

    get    "events/:occurred_at/:event_id/edit", to: "events#edit", as: :edit_child_event
    patch  "events/:occurred_at/:event_id", to: "events#update", as: :child_event
    delete "events/:occurred_at/:event_id", to: "events#destroy", as: :delete_child_event

    # Undo a delete. Clears the tombstone rather than recreating the row, so the
    # sort key and identity survive intact.
    post "events/:occurred_at/:event_id/restore", to: "events#restore",
                                                  as: :restore_child_event
  end

  root "home#index"
end
