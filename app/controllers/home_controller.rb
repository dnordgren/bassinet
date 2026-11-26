class HomeController < ApplicationController
  before_action :require_sign_in!

  def index
    child_repo = Bassinet::ChildRepo.new(household_id: current_household_id)
    @children = child_repo.all
    @selected_child = @children.first
    @today = Bassinet::Dynamo::Marshal.now_ms

    if @selected_child
      events = Bassinet::EventRepo.new(household_id: current_household_id)
                                  .for_day(@selected_child.child_id,
                                           Time.current.in_time_zone(zone_for(@selected_child)).to_date,
                                           timezone: @selected_child.timezone)
                                  .reject(&:deleted?)
      @today_events = events
      @last_by_type = events.group_by(&:type).transform_values(&:first)
      @running = events.find(&:running?)
    end
  end

  private

  def zone_for(child)
    ActiveSupport::TimeZone[child.timezone] || Time.zone
  end
end
