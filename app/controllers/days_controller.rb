class DaysController < ApplicationController
  before_action :require_sign_in!
  before_action :load_child

  # GET /c/:child_id/day/:date
  def show
    @date = Date.parse(params[:date])
    @events = Bassinet::EventRepo.new(household_id: current_household_id)
                                 .for_day(@child.child_id, @date, timezone: @child.timezone)
                                 .reject(&:deleted?)
    @type_filter = params[:type].presence
    @events = @events.select { |e| e.type == @type_filter } if @type_filter
    @running = Bassinet::EventRepo.new(household_id: current_household_id).running(@child.child_id)
  rescue Date::Error
    redirect_to root_path, alert: "That date doesn't exist."
  end

  private

  def load_child
    @child = scoped_child!(params[:child_id])
    redirect_to root_path, alert: "No such child." if @child.nil?
  end
end
