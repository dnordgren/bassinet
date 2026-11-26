module EventsHelper
  ICONS = {
    "diaper" => "🧷",
    "feed" => "🍼",
    "sleep" => "😴",
    "pump" => "🥛",
    "growth" => "📏",
    "note" => "📝"
  }.freeze

  DIAPER_LABELS = {
    "wet" => "Wet diaper",
    "dirty" => "Dirty diaper",
    "mixed" => "Mixed diaper",
    "dry" => "Dry check"
  }.freeze

  FEED_LABELS = {
    "bottle" => "Bottle",
    "nursing" => "Nursing",
    "solids" => "Solids",
    "tube" => "Tube feed"
  }.freeze

  def event_icon(event) = type_icon(event.type)

  def type_icon(type) = ICONS.fetch(type.to_s, "•")

  TYPE_PLURALS = {
    "diaper" => "Diapers",
    "feed" => "Feeds",
    "sleep" => "Sleep",
    "pump" => "Pumps",
    "growth" => "Growth",
    "note" => "Notes"
  }.freeze

  def plural_type_label(type) = TYPE_PLURALS.fetch(type.to_s, type.to_s.pluralize)

  def dom_id_for_event(event) = "event_#{event.event_id}"

  # Views pass a bare child model around; these resolve the timezone once.
  def zone_for(child)
    ActiveSupport::TimeZone[child.timezone] || Time.zone
  end

  def zone_for_child
    current = defined?(@child) && @child ? @child : @selected_child
    ActiveSupport::TimeZone[current.timezone] || Time.zone
  end

  def day_string(ms)
    zone_for_child.at(ms / 1000.0).to_date.to_s
  end

  def event_label(event)
    case event.type
    when "diaper" then DIAPER_LABELS.fetch(event.payload["kind"], "Diaper")
    when "feed" then FEED_LABELS.fetch(event.payload["method"], "Feed")
    when "sleep" then event.running? ? "Sleep (running)" : "Sleep"
    when "pump" then "Pump"
    when "growth" then "Growth"
    when "note" then "Note"
    else event.type.to_s.humanize
    end
  end

  # The one-line "what actually happened" under the label.
  def event_detail(event)
    case event.type
    when "feed"
      parts = []
      parts << "#{event.payload['amount_ml']} ml" if event.payload["amount_ml"]
      parts << event.payload["side"].to_s.capitalize if event.payload["side"].present?
      parts << event.payload["foods"].join(", ") if event.payload["foods"].present?
      parts.join(" · ")
    when "sleep", "pump"
      parts = []
      parts << "#{event.payload['amount_ml_left']} L / #{event.payload['amount_ml_right']} R" if event.payload["amount_ml_left"] || event.payload["amount_ml_right"]
      parts << format_duration(event.duration_s || elapsed_seconds(event)) if event.duration_s.present? || event.running?
      parts << event.payload["quality"].to_s.capitalize if event.payload["quality"].present?
      parts << event.payload["location"] if event.payload["location"].present?
      parts.join(" · ")
    when "growth"
      parts = []
      parts << "#{event.payload['weight_g']} g" if event.payload["weight_g"]
      parts << "#{event.payload['height_mm']} mm" if event.payload["height_mm"]
      parts << "head #{event.payload['head_circumference_mm']} mm" if event.payload["head_circumference_mm"]
      parts.join(" · ")
    when "note"
      event.payload["body"].to_s.truncate(80)
    else
      event.payload["notes"].to_s
    end
  end

  def format_duration(seconds)
    return nil if seconds.nil?

    seconds = seconds.to_i
    minutes = seconds / 60
    return "#{seconds} s" if minutes.zero?

    hours = minutes / 60
    return "#{minutes} min" if hours.zero?

    format("%d h %02d min", hours, minutes % 60)
  end

  def elapsed_seconds(event)
    return nil unless event.running?

    ((Bassinet::Dynamo::Marshal.now_ms - event.started_at) / 1000.0).round
  end

  def clock_time(ms, timezone)
    return "" if ms.nil?

    zone = ActiveSupport::TimeZone[timezone] || Time.zone
    zone.at(ms / 1000.0).strftime("%-I:%M %p")
  end

  def time_ago(ms, now: Bassinet::Dynamo::Marshal.now_ms)
    return "" if ms.nil?

    delta = ((now - ms) / 1000.0).round
    return "just now" if delta.abs < 60

    minutes = delta / 60
    return "#{minutes} min ago" if minutes < 60

    hours = minutes / 60
    return "#{hours} h ago" if hours < 24

    "#{hours / 24} d ago"
  end
end
