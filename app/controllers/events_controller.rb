class EventsController < ApplicationController
  before_action :require_sign_in!
  before_action :load_child

  # GET /c/:child_id/events/new?type=diaper
  def new
    @type = (params[:type].presence || "diaper").to_s
    unless Bassinet::EventPayload.types.include?(@type)
      return redirect_to root_path, alert: "Unknown event type."
    end

    @event = nil
    @occurred_at = params[:occurred_at].presence
    @error = nil
  end

  # POST /c/:child_id/events
  #
  # Handles both the full form and the one-tap tiles: the tiles post a preset
  # payload with `quick=1`, which only changes where we send the user back to.
  def create
    type = params[:type].to_s
    payload = build_payload(type)

    if (error = payload.delete(:__error))
      return respond_with_error(error)
    end

    occurred_at = params[:occurred_at].presence
    at = occurred_at ? parse_ms(occurred_at) : Bassinet::Dynamo::Marshal.now_ms

    event = event_repo.create(
      child_id: @child.child_id,
      event_id: SecureRandom.uuid_v7,
      type: type,
      occurred_at: at,
      author_id: current_user.user_id,
      payload: payload,
      note: params[:note].presence,
      started_at: timer_start(type, at),
      ended_at: nil,
      duration_s: nil,
      source: "web"
    )

    redirect_back_after_create(event)
  rescue Bassinet::Dynamo::Client::ValidationFailed => e
    respond_with_error(e.message)
  end

  # GET /c/:child_id/events/:occurred_at/:event_id/edit
  def edit
    @event = lookup_event!
    return redirect_to root_path, alert: "That entry is gone." if @event.nil?

    @type = @event.type
    @occurred_at = @event.occurred_at
    @error = nil
    render :new
  end

  # PATCH /c/:child_id/events/:occurred_at/:event_id
  def update
    event = lookup_event!
    return redirect_to root_path, alert: "That entry is gone." if event.nil?

    # Stopping a timer is not an edit of the payload; validate only what the
    # client actually sent, then merge over what is already stored.
    payload = params[:stop].present? && params[:payload].blank? ? {} : build_payload(event.type)
    if (error = payload.delete(:__error))
      @event = event
      @type = event.type
      @occurred_at = event.occurred_at
      @error = error
      return render(:new, status: :unprocessable_content)
    end

    # Merge, not replace: a stop request carries no fields, and a partial edit
    # must not drop the ones it did not touch.
    changes = { payload: event.payload.merge(payload) }
    changes[:note] = params[:note].presence

    # Stopping a timer is a normal edit: the client sends the end time.
    if params[:stop].present?
      now = Bassinet::Dynamo::Marshal.now_ms
      changes[:ended_at] = now
      changes[:duration_s] = ((now - (event.started_at || event.occurred_at)) / 1000.0).round
    end

    if params[:ended_at].present?
      changes[:ended_at] = parse_ms(params[:ended_at])
      changes[:duration_s] = ((changes[:ended_at] - (event.started_at || event.occurred_at)) / 1000.0).round
    end

    event_repo.update(
      @child.child_id, event.event_id,
      occurred_at: event.occurred_at,
      changes: changes
    )

    redirect_to child_day_path(@child.child_id, day_for(event.occurred_at)),
                notice: "Entry updated."
  rescue Bassinet::Dynamo::Client::ValidationFailed => e
    respond_with_error(e.message)
  rescue Bassinet::Dynamo::Client::Conflict
    redirect_to child_day_path(@child.child_id, day_for(event.occurred_at)),
                alert: "That entry changed on another device. Reloaded the current version."
  end

  # DELETE /c/:child_id/events/:occurred_at/:event_id
  def destroy
    event = lookup_event!
    return redirect_to root_path, alert: "That entry is gone." if event.nil?

    event_repo.delete(@child.child_id, event.event_id, occurred_at: event.occurred_at)

    day = day_for(event.occurred_at)
    flash[:undo_event] = undo_token(event)
    redirect_to child_day_path(@child.child_id, day),
                notice: "Deleted #{label_for(event).downcase}."
  end

  # POST /c/:child_id/events/:occurred_at/:event_id/restore
  def restore
    occurred_at = params[:occurred_at].to_i
    event = event_repo.restore(@child.child_id, params[:event_id], occurred_at: occurred_at)

    redirect_to child_day_path(@child.child_id, day_for(event.occurred_at)),
                notice: "Restored."
  rescue Bassinet::Dynamo::Client::NotFound
    redirect_to root_path, alert: "That entry is gone."
  end

  private

  def load_child
    @child = scoped_child!(params[:child_id])
    redirect_to root_path, alert: "No such child." if @child.nil?
  end

  def event_repo = Bassinet::EventRepo.new(household_id: current_household_id)

  def lookup_event!
    event_repo.find(@child.child_id, params[:event_id], occurred_at: params[:occurred_at].to_i)
  end

  # Sleep, nursing and pumping are timers: a create also starts the clock, and
  # the stop is a later update rather than a different record.
  def timer_start(type, at)
    return at if type == "sleep"

    return at if type == "feed" && params.dig(:payload, :method) == "nursing"

    nil
  end

  def build_payload(type)
    raw = payload_params(type)
    Bassinet::EventPayload.validate!(type, raw)
  rescue Bassinet::Dynamo::Client::ValidationFailed => e
    { __error: e.message }
  end

  def payload_params(type)
    source = params[:payload]
    return {} if source.blank?

    raw = source.respond_to?(:to_unsafe_h) ? source.to_unsafe_h : source.to_h
    raw = raw.deep_stringify_keys

    # The foods field is one text input rendered as an array tag, so the browser
    # sends a single comma-joined string. Split it here rather than making the
    # user tap "add another" for every banana.
    if type.to_s == "feed" && raw["foods"].is_a?(Array)
      foods = raw["foods"].flat_map { |v| v.to_s.split(",") }.map(&:strip).reject(&:blank?)
      foods.any? ? raw["foods"] = foods : raw.delete("foods")
    end

    raw
  end

  def respond_with_error(message)
    @error = message
    @type = params[:type].to_s.presence || "diaper"
    @event = nil
    @occurred_at = params[:occurred_at].presence

    if params[:quick].present?
      redirect_to child_day_path(@child.child_id, day_for_today), alert: message
    else
      render :new, status: :unprocessable_content
    end
  end

  def redirect_back_after_create(event)
    return redirect_to(root_path, notice: "#{label_for(event)} logged.") if params[:quick].blank?

    redirect_to child_day_path(@child.child_id, day_for(event.occurred_at)),
                notice: "#{label_for(event)} logged."
  end

  def label_for(event) = helpers.event_label(event)

  def day_for(ms)
    zone = ActiveSupport::TimeZone[@child.timezone] || Time.zone
    zone.at(ms / 1000.0).to_date.to_s
  end

  def day_for_today
    zone = ActiveSupport::TimeZone[@child.timezone] || Time.zone
    Time.current.in_time_zone(zone).to_date.to_s
  end

  def parse_ms(value)
    return value.to_i if value.to_s.match?(/\A\d{10,}\z/)

    Bassinet::Dynamo::Marshal.to_ms(value)
  end

  # The undo link has to carry the full identity of the row: the sort key is
  # (occurred_at, event_id), so both are needed to find it again.
  def undo_token(event)
    {
      event_id: event.event_id,
      occurred_at: event.occurred_at,
      label: label_for(event),
      restore_path: restore_child_event_path(@child.child_id, event.occurred_at, event.event_id)
    }
  end
end
