class ChildrenController < ApplicationController
  before_action :require_sign_in!

  def new
    @child = nil
    @timezones = ActiveSupport::TimeZone.all.map(&:name).sort
  end

  def create
    repo = Bassinet::ChildRepo.new(household_id: current_household_id)

    child = repo.create(
      child_id: SecureRandom.uuid,
      name: params.dig(:child, :name),
      birth_date: params.dig(:child, :birth_date).presence,
      timezone: params.dig(:child, :timezone).presence || "America/Chicago",
      units: params.dig(:child, :units).presence || "metric"
    )

    redirect_to root_path, notice: "#{child.name} added."
  rescue Bassinet::Dynamo::Client::ValidationFailed => e
    @error = e.message
    @timezones = ActiveSupport::TimeZone.all.map(&:name).sort
    render :new, status: :unprocessable_content
  end
end
